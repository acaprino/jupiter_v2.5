import asyncio
import math
import uuid
from collections import defaultdict
from typing import Optional, List

from brokers.broker_proxy import Broker
from dto.EconomicEvent import map_from_metatrader, get_symbol_countries_of_interest
from dto.OrderRequest import OrderRequest
from dto.Position import Position
from dto.QueueMessage import QueueMessage
from dto.RequestResult import RequestResult
from misc_utils.bot_logger import BotLogger
from misc_utils.config import ConfigReader, TradingConfiguration
from misc_utils.enums import Timeframe, TradingDirection, OpType, OrderSource, RabbitExchange
from misc_utils.error_handler import exception_handler
from misc_utils.utils_functions import string_to_enum, round_to_point, round_to_step, unix_to_datetime, extract_properties, now_utc, to_serializable
from notifiers.closed_deals_manager import ClosedDealsManager
from routines.base_routine import RagistrationAwareRoutine
from services.rabbitmq_service import RabbitMQService
from strategies.adrastea_strategy import supertrend_slow_key


class AdrasteaSentinelEventManager():

    def __init__(self, config: ConfigReader, trading_configs: List[TradingConfiguration]):
        self.config = config
        self.agent = "AdrasteaSentinelEventManager"
        self.trading_configs = trading_configs
        # Initialize the logger
        self.logger = BotLogger.get_logger(name=f"{self.config.get_bot_name()}_SentinelEventManager", level=config.get_bot_logging_level())
        self.countries_of_interest = {}
        self.clients_registrations = {}
        self.topics = list(
            {f"{config.symbol}.{config.timeframe}.{config.trading_direction}" for config in trading_configs}
        )
        symbol_map = {}
        for config in self.trading_configs:
            symbol = config.symbol
            telegram_config = config.telegram_config
            if symbol not in symbol_map:
                symbol_map[symbol] = set()
            symbol_map[symbol].add(telegram_config)
        self.symbols_to_telegram_configs = {symbol: list(configs) for symbol, configs in symbol_map.items()}

    @exception_handler
    async def routine_start(self):
        symbols = self.topics = list(
            {config.symbol for config in self.trading_configs}
        )

        for symbol in symbols:
            self.countries_of_interest[symbol] = await get_symbol_countries_of_interest(symbol)

        for symbol, symbol_to_telegram_configs in self.symbols_to_telegram_configs:
            self.clients_registrations[symbol] = {}
            for telegram_config in symbol_to_telegram_configs:
                client_id = str(uuid.uuid4())
                self.clients_registrations[symbol][client_id] = telegram_config

                self.logger.info(f"Sending client registration message with id {client_id}")
                registration_payload = to_serializable(telegram_config)
                registration_payload["routine_id"] = client_id

                self.send_queue_message(exchange=RabbitExchange.REGISTRATION,
                                        sender=self.agent,
                                        recipient="middleware")

        for topic in self.topics:
            self.logger.info(f"Listening for economic events on {topic}.")
            exchange_name, exchange_type = RabbitExchange.ECONOMIC_EVENTS.name, RabbitExchange.ECONOMIC_EVENTS.exchange_type
            await RabbitMQService.register_listener(
                exchange_name=exchange_name,
                callback=self.on_economic_event,
                routing_key=topic,
                exchange_type=exchange_type)

    @exception_handler
    async def send_queue_message(self, exchange: RabbitExchange,
                                 payload: dict,
                                 routing_key: Optional[str] = None,
                                 recipient: Optional[str] = None):
        self.logger.info(f"Publishing event message: {payload}")

        recipient = recipient if recipient is not None else "middleware"

        exchange_name, exchange_type = exchange.name, exchange.exchange_type
        tc = {"symbol": "-", "timeframe": "-", "trading_direction": "-", "bot_name": self.config.get_bot_name()}
        await RabbitMQService.publish_message(exchange_name=exchange_name,
                                              message=QueueMessage(sender=self.agent, payload=payload, recipient=recipient, trading_configuration=tc),
                                              routing_key=routing_key,
                                              exchange_type=exchange_type)

    @exception_handler
    async def on_economic_event(self, routing_key: str, message: QueueMessage):
        print(f"Received economic event: {message.payload}")
        broker = Broker()
        broker_offset_hours = await broker.get_broker_timezone_offset()
        event = map_from_metatrader(message.payload, broker_offset_hours)

        event_country = event.country

        event_has_impact = all(event_country in symbol_countries_of_interest for symbol_countries_of_interest in self.countries_of_interest.values())

        if not event_has_impact:
            return

        event_name = event.name
        minutes_until_event = (event.time - now_utc()).total_seconds() / 60
        when_str = f"in {minutes_until_event} minutes." if minutes_until_event > 0 else f"now."

        message = (
            f"📰🔔 Economic event <b>{event_name}</b> is scheduled to occur {when_str}\n"
        )

        impacted_symbols = [symbol for symbol, symbol_countries_of_interest in self.countries_of_interest.items() if event_country in symbol_countries_of_interest]

        for impacted_symbol in impacted_symbols:
            await self.send_message_update(message, impacted_symbol)

        for impacted_symbol in impacted_symbols:

            positions = await broker.get_open_positions(symbol=impacted_symbol)

            if not positions:
                message = f"ℹ️ No open positions found for forced closure due to the economic event <b>{event_name}</b>."
                self.logger.warning(message)
                await self.send_message_update(message, impacted_symbol)
            else:
                for position in positions:
                    # Attempt to close the position
                    result: RequestResult = await broker.close_position(position=position, comment=f"'{event_name}'", magic_number=self.config.get_bot_magic_number())
                    if result and result.success:
                        message = (
                            f"✅ Position {position.position_id} closed successfully due to the economic event <b>{event_name}</b>.\n"
                            f"ℹ️ This action was taken to mitigate potential risks associated with the event's impact on the markets."
                        )
                    else:
                        message = (
                            f"❌ Failed to close position {position.position_id} due to the economic event <b>{event_name}</b>.\n"
                            f"⚠️ Potential risks remain as the position could not be closed."
                        )
                    self.logger.info(message)
                    await self.send_message_update(message, impacted_symbol)

    @exception_handler
    async def send_message_update(self, message: str, symbol: str):
        self.logger.info(f"Publishing event message {message} for symbol {symbol}")
        for client_id, client in self.clients_registrations[symbol]:
            await self.send_queue_message(exchange=RabbitExchange.NOTIFICATIONS, payload={"message": message}, routing_key=client_id)
