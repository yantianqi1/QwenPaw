# -*- coding: utf-8 -*-
"""Monkey-patch OpenAI embeddings to record token usage."""

import functools
import logging
from datetime import date, datetime, timezone
from typing import Any

from .buffer import _UsageEvent
from .manager import get_token_usage_manager

logger = logging.getLogger(__name__)


class EmbeddingUsageRecorder:
    """Patches OpenAI SDK embeddings.create to record token usage.

    Since reme-ai uses the OpenAI-compatible embeddings API internally,
    this recorder intercepts the SDK calls to capture usage metrics
    without modifying the reme-ai library.
    """

    _instance: "EmbeddingUsageRecorder | None" = None

    def __init__(self, model_name: str, provider_id: str = "embedding"):
        self._model_name = model_name
        self._provider_id = provider_id
        self._patched = False
        self._original_create = None
        self._original_acreate = None

    def patch(self) -> None:
        """Monkey-patch openai.resources.embeddings.Embeddings.create."""
        if self._patched:
            return

        try:
            from openai.resources.embeddings import Embeddings
            from openai.resources.embeddings import (
                AsyncEmbeddings,
            )
        except ImportError:
            logger.warning(
                "openai package not available, "
                "embedding usage recording disabled",
            )
            return

        self._original_create = Embeddings.create
        self._original_acreate = AsyncEmbeddings.create

        recorder = self

        @functools.wraps(Embeddings.create)
        def patched_create(self_embed: Any, *args: Any, **kwargs: Any) -> Any:
            response = recorder._original_create(self_embed, *args, **kwargs)
            recorder._record_from_response(response, kwargs)
            return response

        @functools.wraps(AsyncEmbeddings.create)
        async def patched_acreate(
            self_embed: Any, *args: Any, **kwargs: Any
        ) -> Any:
            response = await recorder._original_acreate(
                self_embed, *args, **kwargs
            )
            recorder._record_from_response(response, kwargs)
            return response

        Embeddings.create = patched_create  # type: ignore[method-assign]
        AsyncEmbeddings.create = patched_acreate  # type: ignore[method-assign]
        self._patched = True
        EmbeddingUsageRecorder._instance = self
        logger.info(
            "Embedding usage recorder patched for model=%s",
            self._model_name,
        )

    def unpatch(self) -> None:
        """Restore original embeddings.create methods."""
        if not self._patched:
            return

        try:
            from openai.resources.embeddings import Embeddings
            from openai.resources.embeddings import (
                AsyncEmbeddings,
            )
        except ImportError:
            return

        if self._original_create is not None:
            Embeddings.create = self._original_create  # type: ignore[method-assign]
        if self._original_acreate is not None:
            AsyncEmbeddings.create = self._original_acreate  # type: ignore[method-assign]

        self._patched = False
        EmbeddingUsageRecorder._instance = None
        logger.info("Embedding usage recorder unpatched")

    def _record_from_response(
        self, response: Any, kwargs: dict
    ) -> None:
        """Extract usage from embedding response and enqueue."""
        try:
            usage = getattr(response, "usage", None)
            if usage is None:
                return

            prompt_tokens = getattr(usage, "prompt_tokens", 0) or 0
            if prompt_tokens <= 0:
                return

            model_name = (
                kwargs.get("model") or self._model_name
            )

            event = _UsageEvent(
                provider_id=self._provider_id,
                model_name=model_name,
                prompt_tokens=prompt_tokens,
                completion_tokens=0,
                date_str=date.today().isoformat(),
                now_iso=datetime.now(tz=timezone.utc).isoformat(
                    timespec="seconds",
                ),
            )
            get_token_usage_manager().enqueue(event)
        except Exception:
            logger.debug(
                "Failed to record embedding usage",
                exc_info=True,
            )
