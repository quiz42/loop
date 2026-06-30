# State file modification is blocked

Modifying the loop state file directly is not allowed during an active RLCR loop.

The state file is managed exclusively by the loop framework. Do not attempt to read or write it during loop execution.
