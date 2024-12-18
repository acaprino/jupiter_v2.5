from collections import defaultdict
from collections import defaultdict
from typing import List

from brokers.broker_proxy import Broker
from dto.EconomicEvent import get_symbol_countries_of_interest, EconomicEvent
from dto.QueueMessage import QueueMessage
from dto.RequestResult import RequestResult
from misc_utils.config import ConfigReader, TradingConfiguration
from misc_utils.enums import RabbitExchange
from misc_utils.error_handler import exception_handler
from misc_utils.utils_functions import now_utc
from routines.unique_symbol_agent import SymbolFlatAgent
from services.rabbitmq_service import RabbitMQService


class EconomicEventsManagerAgent(SymbolFlatAgent):

    def __init__(self, config: ConfigReader, trading_configs: List[TradingConfiguration]):
        super().__init__("Economic events manager agent", config, trading_configs)
        self.countries_of_interest = defaultdict(list)

    @exception_handler
    async def start(self):
        for symbol in self.symbols:
            self.countries_of_interest[symbol] = await get_symbol_countries_of_interest(symbol)

        topics = list(
            {f"{symbol}.#" for symbol in self.symbols}
        )

        for topic in topics:
            self.logger.info(f"Listening for economic events on {topic}.")
            exchange_name, exchange_type = RabbitExchange.ECONOMIC_EVENTS.name, RabbitExchange.ECONOMIC_EVENTS.exchange_type
            await RabbitMQService.register_listener(
                exchange_name=exchange_name,
                callback=self.on_economic_event,
                routing_key=topic,
                exchange_type=exchange_type)

    @exception_handler
    async def stop(self):
        pass

    @exception_handler
    async def registration_ack(self, symbol, telegram_configs):
        pass

    @exception_handler
    async def on_economic_event(self, routing_key: str, message: QueueMessage):
        self.logger.info(f"Received economic event: {message.payload}")
        broker = Broker()
        event = EconomicEvent.from_json(message.payload)

        event_country = event.country

        event_has_impact = all(event_country in symbol_countries_of_interest for symbol_countries_of_interest in self.countries_of_interest.values())

        if not event_has_impact:
            return

        event_name = event.name
        total_seconds = (event.time - now_utc()).total_seconds()
        minutes = int(total_seconds // 60)
        seconds = int(total_seconds % 60)

        # Display result
        if minutes == 0 and seconds == 0:
            when_str = "now."
        elif seconds == 0:
            when_str = f"in {minutes} minutes."
        else:
            when_str = f"in {minutes} minutes and {seconds} seconds."

        message = (
            f"📰🔔 Economic event <b>{event_name}</b> is scheduled to occur {when_str}\n"
        )

        impacted_symbols = [symbol for symbol, symbol_countries_of_interest in self.countries_of_interest.items() if event_country in symbol_countries_of_interest]

        for impacted_symbol in impacted_symbols:
            await self.send_message_to_all_clients_for_symbol(message, impacted_symbol)

        for impacted_symbol in impacted_symbols:

            positions = await broker.get_open_positions(symbol=impacted_symbol)

            if not positions:
                message = f"ℹ️ No open positions found for forced closure due to the economic event <b>{event_name}</b>."
                self.logger.warning(message)
                await self.send_message_to_all_clients_for_symbol(message, impacted_symbol)
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
                    await self.send_message_to_all_clients_for_symbol(message, impacted_symbol)