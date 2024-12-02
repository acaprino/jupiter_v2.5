import asyncio
import json
import os
import threading

from datetime import datetime, timedelta
from typing import Dict, List, Optional, Callable, Awaitable, Tuple
from brokers.broker_interface import BrokerAPI
from misc_utils.bot_logger import BotLogger
from misc_utils.error_handler import exception_handler
from misc_utils.utils_functions import now_utc

ObserverCallback = Callable[[Dict], Awaitable[None]]


class CountryEventObserver:
    """Classe che rappresenta un observer per gli eventi di un paese."""

    def __init__(self, country: str, importance: int, callback: ObserverCallback):
        self.country = country
        self.importance = importance
        self.callback = callback
        self.notified_events: set[str] = set()  # Traccia gli eventi già notificati


class EconomicEventManager:
    _instance: Optional['EconomicEventManager'] = None
    _instance_lock: threading.Lock = threading.Lock()

    def __new__(cls) -> 'EconomicEventManager':
        with cls._instance_lock:
            if cls._instance is None:
                instance = super(EconomicEventManager, cls).__new__(cls)
                instance.__initialized = False
                cls._instance = instance
            return cls._instance

    def __init__(self) -> None:
        with self._instance_lock:
            if not self.__initialized:
                # Lock per proteggere le operazioni sugli observer e lo stato
                self._observers_lock: asyncio.Lock = asyncio.Lock()
                self._state_lock: asyncio.Lock = asyncio.Lock()

                # Attributi di istanza
                self.observers: Dict[Tuple[str, int], Dict[str, CountryEventObserver]] = {}
                self.logger: BotLogger = BotLogger.get_logger("EconomicEventManager")
                self._running: bool = False
                self._task: Optional[asyncio.Task] = None
                self.interval_seconds: int = 60 * 5  # 1 minuto
                self.processed_events: Dict[str, datetime] = {}
                self.sandbox_dir = None
                self.json_file_path = None
                self.broker = None
                self.timezone_offset = None

                self.__initialized = True

    def _get_observer_key(self, country: str, importance: int) -> Tuple[str, int]:
        """Crea una chiave univoca per l'observer."""
        return (country, importance)

    @exception_handler
    async def register_observer(self,
                                countries: List[str],
                                broker: BrokerAPI,
                                callback: ObserverCallback,
                                observer_id: str,
                                importance: int = 3):
        """Registra un nuovo observer per una lista di paesi."""
        start_needed = False

        async with self._observers_lock:

            for country in countries:
                key = self._get_observer_key(country, importance)
                if key not in self.observers:
                    self.observers[key] = {}

                observer = CountryEventObserver(country, importance, callback)
                self.observers[key][observer_id] = observer

                self.logger.info(f"Registered observer {observer_id} for country {country}")

            async with self._state_lock:
                # Avvia il monitor se non è già in esecuzione
                if not self.broker:
                    self.broker = broker
                    self.sandbox_dir = await self.broker.get_working_directory()
                    self.json_file_path = os.path.join(self.sandbox_dir, 'economic_calendar.json')
                if not self._running:
                    self._running = True
                    start_needed = True

            if start_needed:
                await self.start()

    @exception_handler
    async def unregister_observer(self, countries: List[str], importance: int, observer_id: str):
        """Rimuove un observer per una lista di paesi."""
        stop_needed = False

        async with self._observers_lock:
            for country in countries:
                key = self._get_observer_key(country, importance)
                if key in self.observers:
                    if observer_id in self.observers[key]:
                        del self.observers[key][observer_id]
                        self.logger.info(f"Unregistered observer {observer_id} for country {country}")

                    # Rimuovi la configurazione se non ha più observers
                    if not self.observers[key]:
                        del self.observers[key]
                        self.logger.info(f"Removed monitoring for country {country}")

            # Ferma il monitor se non ci sono più observers
            async with self._state_lock:
                if not any(self.observers.values()) and self._running:
                    stop_needed = True
            if stop_needed:
                await self.stop()

    async def start(self):
        """Avvia il monitor degli eventi."""
        async with self._state_lock:
            if not self._running:
                self._running = True
                self._task = asyncio.create_task(self._monitor_loop())
                self.logger.info("Economic event monitoring started")

    async def stop(self):
        """Ferma il monitor degli eventi."""
        async with self._state_lock:
            if self._running:
                self._running = False
                if self._task:
                    self._task.cancel()
                    try:
                        await self._task
                    except asyncio.CancelledError:
                        pass
                self.logger.info("Economic event monitoring stopped")

    async def shutdown(self):
        """Ferma il monitor e pulisce le risorse."""
        async with self._state_lock:
            await self.stop()
        async with self._observers_lock:
            self.observers.clear()
            self.processed_events.clear()

    async def _load_events(self) -> Optional[List[Dict]]:
        """Carica e analizza gli eventi economici dal file JSON."""
        if not os.path.exists(self.json_file_path) or os.path.getsize(self.json_file_path) == 0:
            self.logger.error(f"Economic events file not found or empty: {self.json_file_path}")
            return None

        try:
            if self.timezone_offset is None:
                self.timezone_offset = await self.broker.get_broker_timezone_offset("EURUSD")

            with open(self.json_file_path, 'r') as file:
                events = json.load(file)
                for event in events:
                    event['event_time'] = datetime.strptime(
                        event['event_time'],
                        '%Y.%m.%d %H:%M'
                    ) - timedelta(hours=self.timezone_offset)
                return events
        except Exception as e:
            self.logger.error(f"Error loading economic events: {e}")
            return None

    def _cleanup_processed_events(self):
        """Rimuove gli eventi processati scaduti."""
        current_time = now_utc()
        expired_events = [
            event_id for event_id, event_time in self.processed_events.items()
            if event_time <= current_time
        ]
        for event_id in expired_events:
            del self.processed_events[event_id]

    def _cleanup_notified_events(self, current_time: datetime):
        """Pulisce gli eventi notificati scaduti da tutti gli observer."""
        # Rimuovi gli eventi più vecchi di 24 ore
        cutoff_time = current_time - timedelta(hours=24)

        for country_observers in self.observers.values():
            for observer in country_observers.values():
                # Pulisci gli eventi notificati per ogni observer
                expired_events = {
                    event_id for event_id in observer.notified_events
                    if event_id in self.processed_events
                       and self.processed_events[event_id] < cutoff_time
                }
                observer.notified_events.difference_update(expired_events)

    async def _monitor_loop(self):
        """Loop principale di monitoraggio."""
        while self._running:
            try:
                async with self._state_lock:
                    if not self._running:
                        break

                now = now_utc()
                next_run = now + timedelta(seconds=self.interval_seconds)

                self._cleanup_processed_events()
                self._cleanup_notified_events(now)

                events = await self._load_events()
                if not events:
                    await asyncio.sleep(self.interval_seconds)
                    continue

                # Raggruppa tutti gli eventi rilevanti per periodo
                relevant_events = [
                    event for event in events
                    if (now <= event.get('event_time') <= next_run and
                        event.get('event_id') not in self.processed_events)
                ]

                # Per ogni evento rilevante
                for event in relevant_events:
                    event_id = event.get('event_id')
                    event_country = event.get('country_code')
                    event_time = event.get('event_time')
                    event_importance = event.get('event_importance')

                    # Calcola i secondi mancanti all'evento una sola volta
                    seconds_until_event = (event_time - now).total_seconds()
                    event['seconds_until_event'] = seconds_until_event

                    # Raccogli gli observer che devono essere notificati
                    notification_tasks = []

                    # Crea una copia sicura degli observers per l'iterazione
                    async with self._observers_lock:
                        observers_copy = {k: v.copy() for k, v in self.observers.items()}

                    # Raggruppa gli observers per country
                    country_observers: Dict[str, Dict[int, List[CountryEventObserver]]] = {}
                    for (country, importance), observer_group in observers_copy.items():
                        if country not in country_observers:
                            country_observers[country] = {}
                        country_observers[country][importance] = list(observer_group.values())

                    # Per ogni country
                    for country, importance_observers in country_observers.items():
                        # Per ogni importance del simbolo
                        for importance, observers in importance_observers.items():

                            # Verifica che:
                            # 1. L'evento sia abbastanza importante per l'observer
                            # 2. L'observer non sia già stato notificato per questo evento
                            for observer in observers:
                                if (event_importance <= observer.importance and
                                        event_id not in observer.notified_events):
                                    try:
                                        # Aggiungi l'evento alla lista di quelli notificati per questo observer
                                        observer.notified_events.add(event_id)
                                        # Aggiungi il task di notifica
                                        notification_tasks.append(observer.callback(event))
                                    except Exception as e:
                                        self.logger.error(
                                            f"Error processing country {country} with importance {importance}: {e}"
                                        )
                    if notification_tasks:
                        await asyncio.gather(*notification_tasks, return_exceptions=True)
                        self.processed_events[event_id] = event_time

                await asyncio.sleep(self.interval_seconds)

            except Exception as e:
                self.logger.error(f"Error in monitor loop: {e}")
                await asyncio.sleep(5)