# OpenCode usage chunk

## Not recorded (2026-10-13, #557)

`docs/features/usage-and-limits.md` asks for one recorded `usage` chunk of each gateway, OpenCode Go and OpenCode Zen, one of them with a model that writes cache, before the mapping. The probe needs an OpenCode API key, and the machine of the run had none. So no chunk is recorded, and the mapping of `Helyx.Provider.OpenAI.Events` follows the feature doc: `prompt_tokens` minus `prompt_tokens_details.cached_tokens`, `completion_tokens`, `cached_tokens` (0 when absent), cache write 0.
