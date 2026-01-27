#!/usr/bin/env python3
import asyncio
import os

from playwright_mcp_client import PlaywrightWSClient


async def main() -> None:
    ws_url = os.getenv("WS_URL", "ws://localhost:3000")
    token = os.getenv("ACCESS_TOKEN")

    async with PlaywrightWSClient(ws_url, auth_token=token) as client:
        await client.navigate("https://example.com")
        await client.screenshot("example.png")


if __name__ == "__main__":
    asyncio.run(main())
