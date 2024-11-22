# strategies/base_strategy.py

from abc import ABC, abstractmethod

from dto.Position import Position


class StrategyEventHandler(ABC):

    @abstractmethod
    async def start(self):
        pass

    @abstractmethod
    async def stop(self):
        pass

    @abstractmethod
    async def on_message(self, event):
        pass

    @abstractmethod
    async def on_deal_closed(self, position: Position):
        pass
