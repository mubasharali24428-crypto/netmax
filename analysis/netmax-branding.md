# NetMax — Branding Recommendations

## 1. Name Options

### Keep: NetMax ✅ (Recommended)
- **Why it works:** Short, memorable, conveys "network maximum performance." The "Max" suffix implies power and optimization — perfect for a diagnostics tool that finds and fixes network issues fast.
- **Strengths:** Easy to pronounce, strong brand potential, works as a verb ("netmax your network"), unique enough to trademark.
- **Weakness:** Slightly generic; needs strong visual identity to stand out.

### Alternatives

| Name | Rationale | Best For |
|------|-----------|----------|
| **NetPulse** | Real-time monitoring, heartbeat rhythm | Emphasizing live diagnostics |
| **NetSight** | Visibility, insight, network clarity | Emphasizing AI analysis |
| **NetForge** | Building, fixing, crafting connections | Emphasizing repair/fix features |
| **NetRadar** | Detection, scanning, discovery | Emphasizing network discovery |
| **NetLens** | Analysis, focus, clarity | Emphasizing diagnostic depth |
| **NetCore** | Central importance, infrastructure | Emphasizing network infrastructure |
| **NetFlow** | Data movement, traffic analysis | Emphasizing traffic monitoring |
| **NetScope** | Examination, thorough inspection | Emphasizing deep scans |

**Recommendation:** Keep **NetMax** — it's strong, short, and the "Max" suffix pairs well with a terminal/aesthetic brand identity.

---

## 2. Logo Concepts

### Concept A: Network Pulse Ring (Recommended)
```
    ┌─────────────┐
    │  ◉─┐   ┌─◉  │  ← Hexagonal node with pulse rings
    │   │ ┌─┐ │   │
    │   └─┘ └─┘   │  ← Signal waves radiating outward
    │  ◉──────◉  │
    └─────────────┘
```
- A hexagonal network node (represents network topology) with concentric pulse rings (represents AI/speed)
- Single accent color on dark background
- Works at all sizes (favicon to splash screen)

### Concept B: Terminal Prompt
```
  > ⟨  ⟩
  netmax
```
- A terminal prompt `>` followed by a network-style angle bracket `⟨ ⟩`
- Represents the terminal-style output and network diagnostics
- Clean, developer-focused

### Concept C: Diamond Crystal
```
    ◆
   / \
  / AI \
 /______\
```
- A diamond/crystal shape (represents AI precision)
- With a subtle network node inside
- Modern, sleek, memorable

### Concept D: Signal Wave + Circuit
```
  ──∿∿∿──◆──∿∿∿──
```
- Signal wave pattern transitioning into a circuit node
- Represents network diagnostics + AI processing
- Dynamic and energetic

**Recommendation:** **Concept A (Network Pulse Ring)** — it's distinctive, scalable, and visually communicates "network + AI + speed" in a single mark.

---

## 3. Color Palette

### Primary Palette (Dark Mode First)

| Role | Hex | Usage |
|------|-----|-------|
| **Background** | `#0a0e14` | Main app background (deep navy-black) |
| **Surface** | `#161b22` | Cards, panels, elevated elements |
| **Surface Elevated** | `#1e293b` | Modals, dropdowns, popovers |
| **Primary Text** | `#e6edf3` | Headings, primary content |
| **Secondary Text** | `#8b949e` | Muted labels, timestamps |
| **Accent** | `#00d4aa` | Primary CTA, active states, success |
| **Accent Secondary** | `#00bcd4` | Links, hover states, info |

### Semantic Colors

| Role | Hex | Usage |
|------|-----|-------|
| **Success** | `#2ea043` | Healthy connections, passed tests |
| **Warning** | `#f5a623` | Degraded performance, slow responses |
| **Error** | `#f85149` | Failed connections, critical issues |
| **Info** | `#58a6ff` | Informational messages, hints |

### Terminal Colors (for output)

| Role | Hex | Usage |
|------|-----|-------|
| **Green** | `#00d4aa` | Command prompts, success output |
| **Yellow** | `#f5a623` | Warnings, slow responses |
| **Red** | `#f85149` | Errors, failed connections |
| **Cyan** | `#00bcd4` | Info, URLs, IP addresses |
| **White** | `#e6edf3` | Default text |
| **Gray** | `#8b949e` | Muted/disabled text |

### Light Mode (Optional)

| Role | Hex | Usage |
|------|-----|-------|
| **Background** | `#FAFAFA` | Light mode background |
| **Surface** | `#F5F5F5` | Cards, panels |
| **Primary Text** | `#1a1a1a` | Headings |
| **Accent** | `#00d4aa` | Same accent (works on light too) |

---

## 4. Typography Recommendations

### Primary Type Stack

```css
/* Terminal/Code output */
font-family: 'JetBrains Mono', 'Fira Code', 'SF Mono', monospace;

/* UI Elements */
font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;

/* Display/Headers */
font-family: 'Space Grotesk', 'Inter', sans-serif;
```

### Type Scale

| Level | Size | Weight | Usage |
|-------|------|--------|-------|
| **Display** | 32–48px | 700 Bold | App title, hero headers |
| **H1** | 24px | 600 SemiBold | Section headers |
| **H2** | 20px | 600 SemiBold | Subsection headers |
| **Body** | 14–16px | 400 Regular | Primary text |
| **Small** | 12px | 400 Regular | Labels, timestamps |
| **Code** | 13–14px | 400 Regular | Terminal output, JSON |
| **Micro** | 10–11px | 500 Medium | Badges, tags, statuses |

### Terminal-Specific Typography

- **Font:** JetBrains Mono (best for code/terminal readability)
- **Line height:** 1.5–1.6 (generous for code scanning)
- **Letter spacing:** 0 (monospace is naturally spaced)
- **Prompt character:** `>` in accent color
- **Command text:** Primary text color
- **Output text:** Secondary text color
- **Error output:** Error color (#f85149)

### Why These Choices

- **JetBrains Mono:** Designed for code readability, excellent at small sizes, clear distinction between similar characters (0/O, 1/l/I)
- **Inter:** Modern, clean, excellent legibility at UI sizes, large x-height
- **Space Grotesk:** Distinctive but readable, adds personality without being gimmicky, good for display headers

---

## 5. Brand Identity Summary

### NetMax Brand Pillars

1. **Precision** — AI-powered diagnostics, accurate results
2. **Speed** — Fast scans, real-time analysis, instant feedback
3. **Developer-First** — Terminal aesthetic, keyboard-friendly, clean UI
4. **Clarity** — Clear output, semantic colors, no noise

### Brand Voice

- **Tone:** Technical, precise, confident but not arrogant
- **Language:** Direct, action-oriented, no fluff
- **Examples:** "Scanning...", "Connection healthy", "Latency: 12ms", "Issue detected"

### Application Examples

```
┌─────────────────────────────────────┐
│  NetMax v2.4.0                      │
│  ─────────────────────────────────── │
│  > scan network 192.168.1.0/24     │
│                                     │
│  ✅ Gateway (192.168.1.1) — 2ms    │
│  ✅ DNS (8.8.8.8) — 8ms            │
│  ⚠️  Slow host (192.168.1.45) —    │
│     240ms (threshold: 100ms)        │
│  ❌ Failed host (192.168.1.99) —    │
│     Connection refused              │
│                                     │
│  Scan complete: 4 hosts, 1 issue    │
│  >                                   │
└─────────────────────────────────────┘
```
