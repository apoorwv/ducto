"""Typed event emitter for credit lifecycle events.

Events are emitted by ``CreditManager`` after each store operation.
The emitter is optional — inject into ``CreditManager`` constructor,
no-op if omitted.

Usage::

    from ducto.events import CreditEventEmitter

    emitter = CreditEventEmitter()
    emitter.on("credits.deducted", lambda event: print(event))
    manager = CreditManager(store=store, emitter=emitter)
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

# All credit lifecycle event types
CREDIT_EVENT_TYPES = frozenset(
    {
        "credits.deducted",
        "credits.added",
        "credits.refunded",
        "credits.expired",
        "credits.cap_reached",
        "credits.cap_warning",
        "credits.low_balance",
        "credits.plan_changed",
    }
)

CreditEventType = str


@dataclass
class CreditEvent:
    """A typed credit lifecycle event."""

    type: CreditEventType
    timestamp: datetime
    user_id: str
    data: dict[str, Any] | None = None


EventHandler = Callable[[CreditEvent], None]


class CreditEventEmitter:
    """Typed pub/sub event emitter for credit events.

    Handlers are registered by event type string and called synchronously
    when the event is emitted. No-op when no handlers are registered.
    """

    def __init__(self) -> None:
        self._listeners: dict[CreditEventType, list[EventHandler]] = {}

    def on(self, type: CreditEventType, handler: EventHandler) -> None:
        """Register a handler for a specific event type."""
        if type not in self._listeners:
            self._listeners[type] = []
        self._listeners[type].append(handler)

    def off(self, type: CreditEventType, handler: EventHandler) -> None:
        """Remove a previously registered handler."""
        handlers = self._listeners.get(type)
        if handlers:
            from contextlib import suppress

            with suppress(ValueError):
                handlers.remove(handler)

    def emit(self, event: CreditEvent) -> None:
        """Emit an event to all registered handlers."""
        handlers = self._listeners.get(event.type)
        if handlers:
            for handler in handlers:
                handler(event)

    def clear_type(self, type: CreditEventType) -> None:
        """Remove all handlers for a specific type."""
        self._listeners.pop(type, None)

    def clear_all(self) -> None:
        """Remove all handlers for all types."""
        self._listeners.clear()
