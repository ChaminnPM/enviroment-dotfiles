import { Plugin } from "@opencode/plugin/tui"
import { createSignal, onCleanup } from "solid-js"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"

const REFRESH_MS = 5 * 60 * 1000

function cacheFile(): string {
  return path.join(os.homedir(), ".cache", "opencode", "usage-limits.json")
}

function readCache(): any {
  try { return JSON.parse(fs.readFileSync(cacheFile(), "utf8")) } catch { return null }
}

function pct(n: number): string {
  if (!Number.isFinite(n)) return "0"
  return n.toFixed(1)
}

function usd(n: number): string {
  if (!Number.isFinite(n)) return "0.00"
  return n.toFixed(2)
}

function bar(percent: number): string {
  const p = Math.max(0, Math.min(100, percent))
  const filled = Math.round(p / 5)
  return "█".repeat(filled) + "░".repeat(20 - filled)
}

function colorFor(percent: number, theme: any): string {
  if (percent >= 90) return theme?.error ?? "#f38ba8"
  if (percent >= 70) return theme?.warning ?? "#f9e2af"
  return theme?.success ?? "#a6e3a1"
}

function buildDialogText(data: any): string {
  if (!data) return "Sin datos aún. Espera a que se cargue."
  const lines: string[] = []
  lines.push("Límites de uso — OpenCode Go / Zen")
  lines.push("")

  if (data.error) {
    lines.push(`⚠ ${data.error}`)
    lines.push("")
  }

  const go = data.go
  if (go) {
    lines.push(`Go (${go.product ?? "go"}) — renueva ${go.endsAt ?? ""}`)
    const w = (label: string, m: any) => {
      if (!m) return
      lines.push(`  ${label}: $${usd(m.usedUsd)} / $${usd(m.limitUsd)}  ${pct(m.percent)}%`)
      lines.push(`     ${bar(m.percent)}`)
      if (m.resetsAt) lines.push(`     reinicia: ${m.resetsAt}`)
    }
    w("5h   ", go.fiveHour)
    w("Semana", go.week)
    w("Mes   ", go.month)
    lines.push("")
  }

  const zen = data.zen
  if (zen) {
    lines.push("Zen (pay-as-you-go)")
    lines.push(`  Balance: $${usd(zen.balanceUsd)}`)
    if (zen.creditLimitUsd !== null && zen.creditLimitUsd !== undefined) {
      lines.push(`  Límite mensual: $${usd(zen.creditLimitUsd)}`)
    }
    lines.push(`  Modo: ${zen.mode ?? "?"}`)
    lines.push("")
  }

  const s = data.summary30d
  if (s) {
    lines.push("Últimos 30 días")
    lines.push(`  Requests: ${s.requests.toLocaleString()}`)
    lines.push(`  Tokens in/out: ${s.inputTokens.toLocaleString()} / ${s.outputTokens.toLocaleString()}`)
    lines.push(`  Coste: $${usd(s.costUsd)}`)
    lines.push("")
  }

  if (data.fetchedAt) lines.push(`Actualizado: ${data.fetchedAt}`)
  return lines.join("\n")
}

export default Plugin.define({
  id: "usage-limits",
  async setup(context) {
    const [usage, setUsage] = createSignal<any>(readCache())

    const load = () => {
      setUsage(readCache())
    }

    const timer = setInterval(load, REFRESH_MS)

    context.ui.slot({
      append: "home.footer.status",
      render: () => {
        const d = usage()
        if (!d) return <text fg={context.theme.text.muted}>…</text>
        if (d.error) return <text fg={context.theme.error}>⚠ uso</text>
        const go = d.go
        const pctGo = go?.month?.percent ?? 0
        const zenBal = d.zen?.balanceUsd ?? 0
        return (
          <text fg={colorFor(pctGo, context.theme)}>
            Go {pct(pctGo)}% · Zen ${usd(zenBal)}
          </text>
        )
      },
    })

    context.keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "usage-limits.open",
          title: "Show usage limits",
          group: "Usage",
          palette: true,
          slash: { name: "usage", aliases: ["limits"] },
          run: async () => {
            load()
            context.ui.dialog.set({ size: "large", centered: true })
            context.ui.dialog.show(
              () => (
                <box>
                  <text fg={context.theme.text.base}>{buildDialogText(usage())}</text>
                </box>
              ),
              () => {},
            )
          },
        },
        {
          id: "usage-limits.refresh",
          title: "Refresh usage limits",
          group: "Usage",
          palette: true,
          run: async () => {
            load()
            context.ui.toast.show({ message: "Uso actualizado", variant: "success", duration: 2000 })
          },
        },
      ],
    }))

    onCleanup(() => {
      clearInterval(timer)
    })

    return () => {
      clearInterval(timer)
    }
  },
})
