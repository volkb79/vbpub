#!/usr/bin/env python3
"""
Startup script for Playwright MCP Standalone Service.
"""

import asyncio
import logging
import os
import signal
import sys
from typing import List

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

MCP_ENABLED = os.getenv('MCP_ENABLED', 'true').lower() == 'true'
MCP_PORT = int(os.getenv('MCP_PORT', '8765'))
WS_PORT = int(os.getenv('WS_PORT', '3000'))
HEALTH_ENABLED = os.getenv('HEALTH_ENABLED', 'true').lower() == 'true'
HEALTH_PORT = int(os.getenv('HEALTH_PORT', '8081'))


async def run_ws_server() -> None:
    logger.info("Starting WebSocket server on port %s...", WS_PORT)
    from ws_server import PlaywrightWebSocketServer

    server = PlaywrightWebSocketServer()
    await server.start()


async def run_mcp_server() -> None:
    logger.info("Starting MCP server on port %s...", MCP_PORT)

    import uvicorn
    from mcp_server import build_asgi_app

    app = build_asgi_app()

    config = uvicorn.Config(
        app,
        host="0.0.0.0",
        port=MCP_PORT,
        log_level="info",
    )
    server = uvicorn.Server(config)
    await server.serve()


async def run_health_server() -> None:
    logger.info("Starting health server on port %s...", HEALTH_PORT)

    import uvicorn
    from health_server import app

    config = uvicorn.Config(
        app,
        host="0.0.0.0",
        port=HEALTH_PORT,
        log_level="info",
    )
    server = uvicorn.Server(config)
    await server.serve()


async def main() -> None:
    logger.info("=" * 60)
    logger.info("Playwright MCP Standalone Service Starting")
    logger.info("=" * 60)
    logger.info("WebSocket server: ws://0.0.0.0:%s", WS_PORT)
    if MCP_ENABLED:
        logger.info("MCP server: http://0.0.0.0:%s", MCP_PORT)
    else:
        logger.info("MCP server: disabled")
    if HEALTH_ENABLED:
        logger.info("Health server: http://0.0.0.0:%s", HEALTH_PORT)
    else:
        logger.info("Health server: disabled")
    logger.info("=" * 60)

    tasks: List[asyncio.Task] = []
    tasks.append(asyncio.create_task(run_ws_server()))

    if MCP_ENABLED:
        tasks.append(asyncio.create_task(run_mcp_server()))

    if HEALTH_ENABLED:
        tasks.append(asyncio.create_task(run_health_server()))

    loop = asyncio.get_event_loop()

    def signal_handler() -> None:
        logger.info("Received shutdown signal, stopping services...")
        for task in tasks:
            task.cancel()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, signal_handler)

    try:
        await asyncio.gather(*tasks, return_exceptions=True)
    except asyncio.CancelledError:
        logger.info("Services cancelled")
    except Exception as e:
        logger.error("Error running services: %s", e)
        sys.exit(1)
    finally:
        logger.info("Playwright MCP Standalone Service stopped")


if __name__ == "__main__":
    asyncio.run(main())
