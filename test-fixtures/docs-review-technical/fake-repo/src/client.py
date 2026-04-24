"""Example client library."""


class ExampleClient:
    """Client for the Example API."""

    def __init__(self, endpoint: str, api_key: str):
        self.endpoint = endpoint
        self.api_key = api_key

    def list_resources(self, namespace: str = "default") -> list:
        """List all resources in a namespace."""
        return []

    def get_resource(self, name: str) -> dict:
        """Get a single resource by name."""
        return {}
