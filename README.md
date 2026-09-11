# Morpheus PoC — MOR1

Runs against the deployed contract on a mainnet fork pinned to a specific block.
No privileged accounts: attacker and victim are fresh EOAs created by the test.

## Run (one command, from a clean clone)

```bash
git clone --recursive <THIS_REPO_URL> && cd MOR1
ETH_RPC_URL=<your-rpc-url> forge test -vv
```

Foundry only. `--recursive` pulls forge-std. Nothing else to install.
