import asyncio
from typing import Optional

from brokers.broker_interface import BrokerAPI
from dto.OrderRequest import OrderRequest
from dto.Position import Position
from dto.QueueMessage import QueueMessage
from misc_utils.bot_logger import BotLogger
from misc_utils.config import ConfigReader, TradingConfiguration
from misc_utils.enums import Timeframe, TradingDirection, OpType, OrderSource, RabbitExchange
from misc_utils.error_handler import exception_handler
from misc_utils.utils_functions import string_to_enum, round_to_point, round_to_step, unix_to_datetime
from services.rabbitmq_service import RabbitMQService
from strategies.adrastea_strategy import supertrend_slow_key
from strategies.base_event_handler import StrategyEventHandler


class AdrasteaSentinel(StrategyEventHandler):

    def __init__(self, worker_id: str, config: ConfigReader, trading_config: TradingConfiguration, broker: BrokerAPI, queue_service: RabbitMQService):
        self.topic = f"{trading_config.get_symbol()}_{trading_config.get_timeframe().name}_{trading_config.get_trading_direction().name}"
        self.broker = broker
        self.queue_service = queue_service
        self.config = config
        self.trading_config = trading_config
        self.logger = BotLogger.get_logger(name=f"{worker_id}", level=config.get_bot_logging_level().upper())
        self.execution_lock = asyncio.Lock()
        self.signal_confirmations = []
        self.market_open_event = asyncio.Event()
        self.allow_last_tick = False

    @exception_handler
    async def start(self):
        self.logger.info(f"Events handler started for {self.topic}.")

    @exception_handler
    async def stop(self):
        self.logger.info(f"Events handler stopped for {self.topic}.")

    @exception_handler
    async def on_signal_confirmation(self, signal_confirmation: dict):
        self.logger.info(f"Received signal confirmation: {signal_confirmation}")

        symbol = signal_confirmation.get("symbol")
        timeframe = string_to_enum(Timeframe, signal_confirmation.get("timeframe"))
        direction = string_to_enum(TradingDirection, signal_confirmation.get("direction"))
        candle_open_time = signal_confirmation.get("candle").get("time_open")
        candle_close_time = signal_confirmation.get("candle").get("time_close")
        event_timestamp = signal_confirmation.get("timestamp")

        # Check if an older confirmation exists
        existing_confirmation = next(
            (conf for conf in self.signal_confirmations
             if
             conf["symbol"] == symbol
             and conf["timeframe"] == timeframe
             and conf["direction"] == direction
             and conf["time_open"] == candle_open_time
             and conf["time_close"] == candle_close_time),
            None
        )

        if existing_confirmation:
            # Compare confirmation times and update if the new one is more recent
            if event_timestamp > existing_confirmation["event_timestamp"]:
                self.logger.info(f"Updating older confirmation for {symbol} - {timeframe} - {candle_open_time} - {candle_close_time}")
                self.signal_confirmations.remove(existing_confirmation)
                self.signal_confirmations.append(signal_confirmation)
            else:
                self.logger.info(f"Received older confirmation ignored for {symbol} {timeframe}")
        else:
            # Add the new confirmation if none exists
            self.logger.info(f"Adding new confirmation for {symbol} {timeframe}")
            self.signal_confirmations.append(signal_confirmation)

    @exception_handler
    async def on_deal_closed(self, position: Position):
        filtered_deals = list(filter(lambda deal: deal.order_source in {OrderSource.STOP_LOSS, OrderSource.TAKE_PROFIT, OrderSource.MANUAL, OrderSource.BOT}, position.deals))

        if not filtered_deals:
            self.logger.info(f"No stop loss or take profit deals found for position {position.position_id}")
            return

        closing_deal = max(filtered_deals, key=lambda deal: deal.time)

        emoji = "🤑" if position.profit > 0 else "😔"

        trade_details = (
            f"<b>Position ID:</b> {position.position_id}\n"
            f"<b>Timestamp:</b> {closing_deal.time.strftime('%d/%m/%Y %H:%M:%S')}\n"
            f"<b>Market:</b> {position.symbol}\n"
            f"<b>Volume:</b> {closing_deal.volume}\n"
            f"<b>Price:</b> {closing_deal.execution_price}\n"
            f"<b>Order source:</b> {closing_deal.order_source.name}\n"
            f"<b>Profit:</b> {closing_deal.profit}\n"
            f"<b>Commission:</b> {position.commission}\n"
            f"<b>Swap:</b> {position.swap}"
        )

        await self.send_message_update(
            f"{emoji} <b>Deal closed</b>\n\n{trade_details}"
        )

    @exception_handler
    async def place_order(self, order: OrderRequest) -> bool:
        self.logger.info(f"[place_order] Placing order: {order}")

        response = await self.broker.place_order(order)

        self.logger.debug(f"[place_order] Result of order placement: {response.success}")

        self.logger.message = f"{response.server_response_code} - {response.server_response_message}"

        order_details = (
            f"<b>Type:</b> {order.order_type.name}\n"
            f"<b>Market:</b> {order.symbol}\n"
            f"<b>Price:</b> {order.order_price}\n"
            f"<b>Volume:</b> {order.volume}\n"
            f"<b>Stop Loss:</b> {order.sl}\n"
            f"<b>Take Profit:</b> {order.tp}\n"
            f"<b>Comment:</b> {order.comment}\n"
            f"<b>Filling Mode:</b> {order.filling_mode.value if order.filling_mode else 'N/A'}\n"
            f"<b>Magic Number:</b> {order.magic_number if order.magic_number else 'N/A'}"
        )

        if response.success:
            self.logger.info(f"[place_order] Order successfully placed. Broker log: \"{response.server_response_message}\"")
            await self.send_message_update(f"✅ <b>Order successfully placed with Deal ID {response.deal}:</b>\n\n{order_details}")
        else:
            self.logger.error("[place_order] Error while placing the order.")
            await self.send_message_update(f"🚫 <b>Error while placing the order:</b>\n\n{order_details}\n Broker log: \"{response.server_response_message}\"")

        return response.success

    def get_take_profit(self, cur_candle: dict, order_price, symbol_point, timeframe, trading_direction):
        atr_periods = 5 if trading_direction == TradingDirection.SHORT else 2
        atr_key = f'ATR_{atr_periods}'
        atr = cur_candle[atr_key]
        multiplier = 1 if timeframe == Timeframe.M30 else 2
        multiplier = multiplier * -1 if trading_direction == TradingDirection.SHORT else multiplier
        take_profit_price = order_price + (multiplier * atr)

        # Return the take profit price rounded to the symbol's point value
        return round_to_point(take_profit_price, symbol_point)

    def get_stop_loss(self, cur_candle: dict, symbol_point, trading_direction):
        # Ensure 'supertrend_slow_key' is defined or passed to this function
        supertrend_slow = cur_candle[supertrend_slow_key]

        # Calculate stop loss adjustment factor
        adjustment_factor = 0.003 / 100

        # Adjust stop loss based on trading direction
        if trading_direction == TradingDirection.LONG:
            sl = supertrend_slow - (supertrend_slow * adjustment_factor)
        elif trading_direction == TradingDirection.SHORT:
            sl = supertrend_slow + (supertrend_slow * adjustment_factor)
        else:
            raise ValueError("Invalid trading direction")

        # Return the stop loss rounded to the symbol's point value
        return round_to_point(sl, symbol_point)

    def get_order_price(self, cur_candle: dict, symbol_point, trading_direction) -> float:
        """
        This function calculates the order price for a trade based on the trading direction and a small adjustment factor.

        Parameters:
        - candle (dict): A dictionary containing the OHLC (Open, High, Low, Close) values for a specific time period.
        - symbol_point (float): The smallest price change for the trading symbol.
        - trading_direction (TradingDirection): An enum value indicating the trading direction (LONG or SHORT).

        Returns:
        - float: The adjusted order price, rounded to the symbol's point value.

        The function first determines the base price based on the trading direction. If the direction is LONG, the base price is the high price of the Heikin Ashi candle; if the direction is SHORT, the base price is the low price of the Heikin Ashi candle.

        Then, it calculates a small adjustment to the base price. The adjustment is a fixed percentage (0.003%) of the base price. The adjustment is added to the base price for LONG trades and subtracted from the base price for SHORT trades.

        Finally, the function returns the adjusted price, rounded to the symbol's point value.
        """
        # Determine the base price based on trading direction.
        base_price_key = 'HA_high' if trading_direction == TradingDirection.LONG else 'HA_low'
        base_price = cur_candle[base_price_key]

        # Calculate the price adjustment.
        adjustment_factor = 0.003 / 100
        adjustment = adjustment_factor * base_price
        adjusted_price = base_price + adjustment if trading_direction == TradingDirection.LONG else base_price - adjustment

        # Return the price rounded to the symbol's point value.
        return round_to_point(adjusted_price, symbol_point)

    def get_volume(self, account_balance, symbol_info, entry_price, stop_loss_price):
        risk_percent = self.trading_config.get_risk_percent()
        self.logger.info(
            f"Calculating volume for account balance {account_balance}, symbol info {symbol_info}, entry price {entry_price}, stop loss price {stop_loss_price}, and risk percent {risk_percent}")
        risk_amount = account_balance * risk_percent
        stop_loss_pips = abs(entry_price - stop_loss_price) / symbol_info.point
        pip_value = symbol_info.trade_contract_size * symbol_info.point
        volume = risk_amount / (stop_loss_pips * pip_value)
        # Adjust volume to meet broker's constraints
        adjusted_volume = max(
            symbol_info.volume_min,
            min(symbol_info.volume_max, round_to_step(volume, symbol_info.volume_step))
        )
        return adjusted_volume

    @exception_handler
    async def prepare_order_to_place(self, cur_candle: dict) -> Optional[OrderRequest]:
        symbol = self.trading_config.get_symbol()
        trading_direction = self.trading_config.get_trading_direction()
        order_type_enter = OpType.BUY if trading_direction == TradingDirection.LONG else OpType.SELL
        timeframe = self.trading_config.get_timeframe()
        magic_number = self.config.get_bot_magic_number()

        symbol_info = await self.broker.get_market_info(symbol)

        if symbol_info is None:
            self.logger.error("[place_order] Symbol info not found.")
            await self.send_message_update("🚫 Symbol info not found for placing the order.")
            raise Exception(f"Symbol info {symbol} not found.")

        point = symbol_info.point
        volume_min = symbol_info.volume_min

        price = self.get_order_price(cur_candle, point, trading_direction)
        sl = self.get_stop_loss(cur_candle, point, trading_direction)
        tp = self.get_take_profit(cur_candle, price, point, timeframe, trading_direction)

        account_balance = await self.broker.get_account_balance()

        volume = self.get_volume(account_balance=account_balance, symbol_info=symbol_info, entry_price=price, stop_loss_price=sl)

        self.logger.info(f"[place_order] Account balance retrieved: {account_balance}, Calculated volume for the order on {symbol} at price {price}: {volume}")

        if volume < volume_min:
            self.logger.warning(f"[place_order] Volume of {volume} is less than minimum of {volume_min}")
            await self.send_message_update(f"❗ Volume of {volume} is less than the minimum of {volume_min} for {symbol}.")
            return None

        filling_mode = await self.broker.get_filling_mode(symbol)
        self.logger.debug(f"Filling mode for {symbol}: {filling_mode}")

        return OrderRequest(order_type=order_type_enter,
                            symbol=symbol,
                            order_price=price,
                            volume=volume,
                            sl=sl,
                            tp=tp,
                            comment="bot-enter-signal",
                            filling_mode=filling_mode,
                            magic_number=magic_number)

    @exception_handler
    async def send_queue_message(self, exchange: RabbitExchange,
                                 payload: dict,
                                 routing_key: Optional[str] = None,
                                 recipient: Optional[str] = None):
        self.logger.info(f"Publishing event message: {payload}")

        recipient = recipient if recipient is not None else "middleware"
        payload["symbol"] = self.trading_config.get_symbol()
        payload["timeframe"] = self.trading_config.get_timeframe().name
        payload["direction"] = self.trading_config.get_trading_direction().name

        exchange_name, exchange_type = exchange.name, exchange.exchange_type
        await self.queue_service.publish_message(exchange_name=exchange_name, message=QueueMessage(sender=self.config.get_bot_name(), payload=payload, recipient=recipient), routing_key=routing_key,
                                                 exchange_type=exchange_type)

    @exception_handler
    async def send_message_update(self, message: str):
        bot_token = self.trading_config.get_telegram_config().token
        chat_ids = self.trading_config.get_telegram_config().chat_ids
        self.logger.info(f"Publishing event message: {message} for topic {bot_token}")
        await self.send_queue_message(exchange=RabbitExchange.NOTIFICATIONS, payload={"message": message, "chat_ids": chat_ids}, routing_key=bot_token)

    @exception_handler
    async def on_market_status_change(self, is_open: bool, closing_time: float, opening_time: float, initializing: bool):
        async with self.execution_lock:
            symbol = self.trading_config.get_symbol()
            time_ref = opening_time if is_open else closing_time
            self.logger.info(f"Market for {symbol} has {'opened' if is_open else 'closed'} at {unix_to_datetime(time_ref)}.")
            if is_open:
                self.market_open_event.set()
                if initializing and not self.config.get_param("start_silent"):
                    await self.send_message_update(f"🟢 Market for {symbol} is <b>open</b>.")
                else:
                    await self.send_message_update(f"⏰🟢 Market for {symbol} has just <b>opened</b>. Resuming trading activities.")
            else:
                self.market_open_event.clear()
                if initializing and not self.config.get_param("start_silent"):
                    await self.send_message_update(f"⏸️ Market for {symbol} is <b>closed</b>.")
                else:
                    self.logger.info("Allowing the last tick to be processed before fully closing the market.")
                    self.allow_last_tick = True
                    await self.send_message_update(f"🌙⏸️ Market for {symbol} has just <b>closed</b>. Pausing trading activities.")
