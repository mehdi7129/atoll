# competitors

## Summary
The "AI agent in the notch/menu bar" category exploded in late 2025–2026 and is now crowded with 20+ macOS apps in three overlapping tiers: interactive notch panels (Vibe Island $15–19.99 one-time and its free/open-source rivals Vibe Notch/Claude Island 2.5k stars, Open Island 1.6k stars, xisland, NotchCode $19.99, NotchPilot €4.99, MioIsland, Notchi, AgentNotch, CodeIsland, Ping Island, Tars Notch, Clautch, Buddi, agent-island), menu bar session monitors (so-agentbar, claude-status, claude-watch, claude-control), and usage/quota trackers (ccusage CLI as the de-facto standard, Maciek-roboblog/Claude-Code-Usage-Monitor, CCSeva, Usage4Claude, ClaudeBar, SessionWatcher $6.99+). The winning feature set is already established: hook-based session detection via Unix socket, permission approve/deny from the notch, question answering, plan review with Markdown, precise terminal jump-back (incl. tmux/split panes/IDE terminals), quota tracking, and sound alerts. User complaints cluster on reliability, not features: ghost/stale sessions that never clear, missed events from IDE-embedded agents (Cursor, Claude Desktop), jump-back failing for daemon/background sessions, SSH monitoring lockups, notch overlays blocking clicks during computer-use, usage numbers exceeding 100% or drifting from actual limits, Electron bloat, Mixpanel telemetry in "open-source" apps, and maintainer abandonment (vibe-notch had a 4-month gap). Nobody credibly combines session control + accurate quota tracking + subagent visibility + phone escalation in one reliable native app; cross-platform (Windows/Linux), multi-machine/SSH done right, team visibility, and notify-only-when-unfocused intelligence are the open gaps. A new app wins on trustworthy session lifecycle across all host environments, official-endpoint-accurate usage data, and mobile push escalation — not on more agent logos.

## Key findings
- Vibe Island (vibeisland.app, community repo github.com/vibeislandapp/vibe-island, 75 stars/89 open issues): commercial $15 (earlier beta $19.99) one-time, native Swift <50MB RAM, 25-26 agents, 20+ terminals, permission approve/deny, question answering, plan review with Markdown, terminal jump incl. split panes/tmux/Zellij, per-provider usage quotas (Claude/Codex/Kimi/GLM/DeepSeek), SSH remote monitoring, 8-bit sound packs, zero-config auto CLI detection; endorsed virally on X ('best mac app of 2026' — @ideabrowser license giveaway).
- Vibe Island's own issue tracker reveals the category's failure modes: notch blocks clicks during Claude computer-use; question sessions never marked done; jump silently no-ops for daemon-hosted sessions; quota missing for Claude Desktop; Cursor agent questions not displayed; stale status after process exit (qoder); SSH reconnect loop 'eventually locks up computer'; open requests = Windows remote, pt-BR localization, multi-screen support, event-only mode for persistent desktop agents.
- Vibe Notch, formerly Claude Island (github.com/farouqaldori/vibe-notch, claudeisland.com): Apache-2.0, 2,500 stars/342 forks, Claude Code ONLY, hooks in ~/.claude/hooks -> Unix socket, permission approvals, full chat history with markdown, auto-setup, macOS 15.6+; demerits: Mixpanel analytics, 4-month maintenance gap (Dec 2025 v1.2 -> Apr 2026 v1.3), 26 open issues + 23 unmerged PRs.
- Open Island (github.com/Octane0411/open-vibe-island): GPL-3.0, 1.6k stars, 50 releases, the strongest free multi-agent rival — 10 agents (Claude Code, Codex CLI+Desktop, OpenCode, Cursor, Gemini CLI, Kimi CLI, Qoder, Qwen Code, Factory, CodeBuddy), 15+ terminals incl. tmux/cmux/Zellij/JetBrains/Warp, architecture = hooks -> Unix socket BridgeServer + JSONL transcript discovery + ps/lsof process detection, 4 Swift targets, Sparkle auto-update, signed+notarized, EN/zh-CN i18n, no telemetry; admits Claude Desktop usage panel can't self-update and Codex file-edit approval isn't guaranteed PreToolUse.
- Other notch competitors: xisland.app (free, Swift, notch AND pill mode for non-notch Macs, vim hjkl keyboard-first, 4 agents); NotchCode (notchcode.dev, $19.99, Claude/Gemini/Codex, tmux integration, 1-Mac license); NotchPilot (€4.99, github.com/devmegablaster/Notch-Pilot); MioIsland (github.com/MioMioOS/MioIsland, CC BY-NC, 515 stars, unique iPhone dual-sync companion with reply previews and remote session launch, socket /tmp/codeisland.sock); Notchi (sk-ruban/notchi, GPL-3.0, pixel-sprite pets per session, mostly read-only); AgentNotch (AppGram/agentnotch, Claude+Codex tokens/cost, manual Homebrew setup); CodeIsland (wxtsky, MIT); Ping Island (erha19); Tars Notch (ohernandezdev, Claude + GitHub Copilot CLI, subagent tracking); Clautch (clautch.app, team rooms — only team-visibility play); Buddi (Product Hunt, ASCII pets). Curated index of all: github.com/ChenSiWu/notch-island-tools.
- agent-island (github.com/tristan666666/agent-island, MIT, 68 stars) is the ONLY cross-platform one: macOS 13+ AND Windows 10/11; no hooks — local transcript-file parser + file events; pulls usage from provider-owned usage endpoints via local credential store (accurate, not estimated); queued 'your-turn' alerts instead of replacing notifications; shareable weekly report cards. Linux is served only by gnotchi (GNOME mascot) and mryll/claudebar (Waybar, pure Bash, OAuth refresh).
- Menu bar session monitors: so-agentbar (sotthang, Claude Code + Codex realtime, tokens/costs/status, subagents folded under parent with robot-emoji xN badge); gmr/claude-status (menu bar + desktop widget, ships a Claude Code plugin writing .cstatus files + Darwin notifications + FS watching + polling); sooink/claude-watch (parallel subagent task progress); m1ckc3s/claude-status-bar (animated icon, elapsed timer, awaiting-permission dot); sverrirsig/claude-control (dashboard: auto-discovered sessions, git changes, conversation previews).
- Usage trackers: ccusage (ccusage.com) is the substrate — local JSONL parsing across 15+ CLIs (Claude Code, Codex, Gemini, Copilot CLI, Goose, Amp…), many GUIs just shell out to it. Maciek-roboblog/Claude-Code-Usage-Monitor (pip install claude-monitor, burn rate, P90 predictions) got HN flak for usage >100%, confusing resets, hardcoded 7k Pro token limit, Poland timezone default, vibe-coded 1000-line main. CCSeva (Iamshankhadeep, Electron, 30s updates, plan auto-detect Pro/Max5/Max20, 70%/90% alerts, 7-day charts). Usage4Claude (f-is-h) tracks 5h, 7d, extra usage, 7-day Opus AND 7-day Sonnet quotas separately. lionhylra/cc-usage-bar markets 'data straight from Claude Code itself, always 100% accurate' — accuracy is a known sore point. SessionWatcher (commercial $6.99–$59) adds multi-tool (Cursor/Copilot/Devin/Antigravity) and multi-account tracking. tddworks/ClaudeBar covers Claude/Codex/Antigravity/Gemini quotas.
- Adjacent orchestrators define the ceiling: smtg-ai/claude-squad (TUI, tmux + git worktrees), Conductor (native macOS parallel worktree agents + diff review), VibeTunnel (browser remote + menu bar), Happy (happy.engineering, open-source iOS/Android/web remote control, E2E encrypted, push notifications for permissions/completion, wrap command 'happy' instead of 'claude'), Tactic Remote (clauderc.com/tacticremote.com), plus Anthropic's official Remote Control (code.claude.com/docs/en/remote-control), /usage command, and statusline — official features keep eating the low end of pure usage display.
- Standard technical recipe across the category: register Claude Code/Codex hooks (Notification/Stop/PreToolUse) that POST JSON to a Unix socket; supplement with ~/.claude/projects JSONL transcript tailing and ps/lsof process detection; jump-back via AppleScript/Accessibility to specific terminal tab/pane. Detection WITHOUT hooks (transcript watching) is the more robust fallback when hooks fail or the agent runs headless.
- What users praise: staying in flow (no cmd-tab), approving from the notch, quota-anxiety relief with reset countdowns, native Swift low-RAM feel, sound alerts, precise terminal jumping, zero-config setup. What they complain about: ghost/stale sessions, missed events from IDE-embedded and desktop-app agents, broken jump for background daemons, SSH instability, inaccurate usage math, Electron bloat, telemetry, paid gate for commodity features, macOS-only, single-monitor, and abandonware risk.

## Recommendations
- Compete on reliability, not agent-logo count: bulletproof session lifecycle (no ghost sessions; explicit exit/crash detection via process + transcript reconciliation), support for daemon/background/SDK-spawned sessions, IDE-embedded terminals (Cursor, Windsurf, JetBrains), and Claude Desktop — these are the top recurring bug themes in every competitor's issue tracker.
- Unify the three fragmented tiers in one app: live session state + approvals (Vibe Island tier), subagent tree visibility (claude-watch/so-agentbar tier), and ACCURATE quota tracking from official OAuth usage endpoints rather than JSONL cost estimation (only agent-island and Usage4Claude do this; estimation drift is the #1 usage-tracker complaint).
- Add phone escalation as the killer differentiator: if a permission request or question isn't acknowledged on the notch within N seconds, push to iPhone with reply/approve actions (only MioIsland gestures at this; Happy does it but has no notch presence). Smart notification logic — alert only when the terminal isn't focused, queue rather than replace 'your turn' alerts, DND-aware.
- Cover the requested-but-unserved surface: multi-monitor support, pill/menu-bar mode for non-notch Macs (xisland precedent), event-only mode for persistent desktop agents, reliable SSH/multi-machine monitoring (Vibe Island's is unstable), Windows remote targets, and localization (pt-BR explicitly requested).
- Make the overlay click-through during agent computer-use sessions (a documented Vibe Island bug) and never intercept the screen region an agent is controlling.
- Positioning: free open-source core (GPL/Apache, signed+notarized, Sparkle auto-update, zero telemetry — vibe-notch's Mixpanel is held against it) with an optional paid tier for phone sync/team rooms; the $15–20 one-time price ceiling is already set, and 1.6k–2.5k-star free alternatives cap what basic features can charge.
- Interactive depth beyond approve/deny: send follow-up prompts and steer sessions from the notch, review plans AND diffs inline, jump-back that handles tmux/Zellij/split panes — plan review is Vibe Island's moat today; diff review from the notch is unclaimed (Conductor requires a full app).
- Team/multiplayer visibility (who's running what, shared quota burn) is essentially unclaimed — only Clautch's 'team rooms' attempts it; a lightweight team mode would be a genuinely new category entry.

## Sources
- https://vibeisland.app/claude-code/
- https://vibeisland.app/alternatives/
- https://github.com/vibeislandapp/vibe-island
- https://github.com/vibeislandapp/vibe-island/issues
- https://github.com/farouqaldori/vibe-notch
- https://github.com/Octane0411/open-vibe-island
- https://github.com/ChenSiWu/notch-island-tools
- https://xisland.app/
- https://notchcode.dev/
- https://notchpilot.app/
- https://github.com/MioMioOS/MioIsland
- https://github.com/sk-ruban/notchi
- https://github.com/AppGram/agentnotch
- https://github.com/tristan666666/agent-island
- https://github.com/wxtsky/CodeIsland
- https://github.com/erha19/ping-island
- https://github.com/ohernandezdev/tars-notch
- https://clautch.app/
- https://www.producthunt.com/products/buddi-living-in-the-notch
- https://github.com/sotthang/so-agentbar
- https://github.com/gmr/claude-status
- https://github.com/sooink/claude-watch
- https://github.com/m1ckc3s/claude-status-bar
- https://github.com/sverrirsig/claude-control
- https://github.com/hoangsonww/Claude-Code-Agent-Monitor
- https://ccusage.com/
- https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor
- https://news.ycombinator.com/item?id=44317012
- https://github.com/Iamshankhadeep/ccseva
- https://github.com/f-is-h/Usage4Claude
- https://github.com/tddworks/ClaudeBar
- https://github.com/lionhylra/cc-usage-bar
- https://github.com/leeguooooo/claude-code-usage-bar
- https://github.com/joachimBrindeau/ccusage-monitor
- https://github.com/mryll/claudebar
- https://github.com/CodeZeno/Claude-Code-Usage-Monitor
- https://sessionwatcher.com/guides/best-claude-code-usage-trackers
- https://github.com/smtg-ai/claude-squad
- https://www.andreagrandi.it/posts/using-vibetunnel-to-control-claude-code-instances-remotely/
- https://happy.engineering/
- https://tacticremote.com/
- https://code.claude.com/docs/en/remote-control
- https://x.com/ideabrowser/status/2039861754981671360
- https://x.com/Iamshankhadeep/status/1939357857033626074
- https://www.d12frosted.io/posts/2026-01-05-claude-code-notifications
- https://wmedia.es/en/tips/claude-code-notify-when-done
- https://github.com/Gheop/gnotchi
- https://github.com/rjwalters/claude-monitor
- https://github.com/hamed-elfayome/Claude-Usage-Tracker
- https://www.claudeusagebar.com/
- https://munderdiffl.in/blog/best-claude-code-multi-agent-tools/
