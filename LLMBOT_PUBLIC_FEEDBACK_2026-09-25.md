# LLMbot: public problem and user-feedback corpus

**Researched:** 2026-09-25. **Repo:** https://github.com/ckryptickunal/LLMbot. **Scope:** Bot-Harness, an early-construction local-first macOS AI bot framework; permission and access problem space.

**Evidence boundary:** These are problem-space reports about comparable workflows/products, not users of this repository. Some are questions or interested builders rather than verified defects. Follow each original link before using an item for implementation. Relevance is a product hypothesis, not a claim that Kunal’s repo currently behaves this way.

## Source records

### LLMBOT-01
- date: 2026-01-29
- audience: Local assistant builder
- evidence: A user wants an AI to read personal Documents/Desktop/Photos without modifying or deleting them, using an isolated output workspace.
- source: https://www.reddit.com/r/LocalLLM/comments/1qqmkka/setting_up_local_ai_with_readonly_access_to/
- LLMbot relevance: Make per-folder read/write scope enforceable and inspectable.

### LLMBOT-02
- date: 2026-04-05
- audience: Local-agent community
- evidence: A user asks why agents need broad system access and raises the trust question around tools such as OpenClaw.
- source: https://www.reddit.com/r/LocalLLaMA/comments/1scp2a1/am_i_missing_something_with_ai_agents_that_need/
- LLMbot relevance: Explain which local privileges each bot needs and how to revoke them.

### LLMBOT-03
- date: 2026-04-24
- audience: Coding-agent user
- evidence: A user flags lack of a default sandbox as a safety concern for a local agent.
- source: https://www.reddit.com/r/LocalLLaMA/comments/1sunkcq/pidev_coding_agent_as_no_sandbox_by_default/
- LLMbot relevance: Treat filesystem and shell access as a design constraint; compare sandboxed and unsandboxed modes.

### LLMBOT-04
- date: 2025-10-11
- audience: Local model user
- evidence: The author built a Discord bridge to use LM Studio/Ollama on mobile and retain chat ratings/logs. This is a maker use case, not a complaint.
- source: https://www.reddit.com/r/LocalLLaMA/comments/1o4290b/wanted_to_share_tool_for_linking_lm_studioollama/
- LLMbot relevance: Mobile conversation continuity matters for local bots; ensure logs stay under owner control.

## Assessment and limits

The source sample is narrow. It shows concrete problems worth checking, not a complete market survey or proof of demand for this specific repo. For promising signals, test the current repo against a user scenario and ask actual users before turning it into a roadmap. No private repository content used.
