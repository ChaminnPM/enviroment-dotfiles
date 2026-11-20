/** @jsxImportSource @opentui/solid */
import { Plugin } from "@opencode/plugin/tui"
import { createSignal, For } from "solid-js"
import * as fs from "node:fs"
import * as os from "node:os"
import * as path from "node:path"

type QuotaWindow = {
  id: string
  label: string
  percentRemaining: number
  resetTimeIso?: string
}
type QuotaProvider = {
  id: string
  label: string
  status: string
  error?: string
  hint?: string
  windows: QuotaWindow[]
}
type Snapshot = {
  generatedAt?: string
  providers: QuotaProvider[]
}

const SNAPSHOT_PATH = path.join(
  os.homedir(),
  ".cache",
  "opencode-quota-extended",
  "last-snapshot.json",
)

function readSnapshot(): Snapshot {
  try {
    const raw = JSON.parse(fs.readFileSync(SNAPSHOT_PATH, "utf8"))
    return (raw?.snapshot ?? { providers: [] }) as Snapshot
  } catch {
    return { providers: [] }
  }
}

function bar(percent: number): string {
  const value = Math.max(0, Math.min(100, percent))
  const filled = Math.round(value / 5)
  return "█".repeat(filled) + "░".repeat(20 - filled)
}

function colorFor(percent: number, theme: any): string {
  if (percent >= 50) return theme?.status?.success ?? "#50fa7b"
  if (percent >= 25) return theme?.status?.warning ?? "#f1fa8c"
  return theme?.status?.danger ?? "#ff5555"
}

export default Plugin.define({
  id: "quota-window",
  setup(context) {
    const [snapshot, setSnapshot] = createSignal<Snapshot>(readSnapshot())
    const [updatedAt, setUpdatedAt] = createSignal("")

    const refresh = () => {
      setSnapshot(readSnapshot())
      const iso = snapshot().generatedAt
      setUpdatedAt(iso ? new Date(iso).toLocaleTimeString() : "—")
    }

    refresh()
    const timer = setInterval(refresh, 15_000)

    const openWindow = () => {
      refresh()
      context.ui.dialog.set({ size: "large", centered: true })
      context.ui.dialog.show(
        () => {
          const t: any = context.theme
          const providers = () => snapshot().providers
          const statusColor = (status: string) => {
            if (status === "ok") return t?.status?.success ?? "#50fa7b"
            if (status === "stale") return t?.status?.warning ?? "#f1fa8c"
            if (status === "error") return t?.status?.danger ?? "#ff5555"
            return t?.text?.muted ?? "#6272a4"
          }
          const textColor = t?.text?.base ?? "#f8f8f2"
          const mutedColor = t?.text?.muted ?? "#6272a4"
          const accentColor = t?.action?.primary?.base ?? "#bd93f9"
          const panelColor =
            t?.background?.raised?.base ??
            t?.background?.panel?.base ??
            "#282a36"

          return (
            <box
              flexDirection="column"
              gap={1}
              width="100%"
              border
              borderStyle="rounded"
              borderColor={accentColor}
              backgroundColor={panelColor}
              paddingLeft={2}
              paddingRight={2}
              paddingTop={1}
              paddingBottom={1}
            >
              <box
                flexDirection="row"
                width="100%"
                justifyContent="space-between"
              >
                <text fg={accentColor}>◆ QUOTA · ALL PROVIDERS</text>
                <text fg={mutedColor}>{providers().length} providers</text>
              </box>
              <text fg={mutedColor}>{"─".repeat(68)}</text>
              <For each={providers()}>
                {(provider) => (
                  <box flexDirection="column" gap={0} width="100%">
                    <box
                      flexDirection="row"
                      width="100%"
                      justifyContent="space-between"
                    >
                      <text fg={textColor}>{provider.label}</text>
                      <text fg={statusColor(provider.status)}>
                        {provider.status}
                      </text>
                    </box>
                    <For each={provider.windows}>
                      {(window) => (
                        <box flexDirection="row" gap={1} width="100%">
                          <text fg={mutedColor} width={11}>
                            {window.label}
                          </text>
                          <text fg={colorFor(window.percentRemaining, t)}>
                            {bar(window.percentRemaining)}
                          </text>
                          <text
                            fg={colorFor(window.percentRemaining, t)}
                            width={4}
                          >
                            {String(Math.round(window.percentRemaining)).padStart(3)}%
                          </text>
                          <text fg={mutedColor}>
                            {window.resetTimeIso
                              ? window.resetTimeIso.slice(0, 10)
                              : "—"}
                          </text>
                        </box>
                      )}
                    </For>
                    {provider.hint ? (
                      <text fg={mutedColor}>{provider.hint}</text>
                    ) : null}
                    {provider.error ? (
                      <text fg={statusColor("error")}>{provider.error}</text>
                    ) : null}
                  </box>
                )}
              </For>
              <text fg={mutedColor}>{"─".repeat(68)}</text>
              <text fg={mutedColor}>
                {`/quota or Ctrl+X O  ·  Esc to close  ·  updated ${updatedAt()}`}
              </text>
            </box>
          )
        },
        () => {},
      )
    }

    context.keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "quota-window.show",
          title: "Quota: open all providers",
          group: "Quota",
          bind: "<leader>o",
          palette: true,
          slash: { name: "quota" },
          run: () => openWindow(),
        },
      ],
      bindings: ["quota-window.show"],
    }))

    return () => clearInterval(timer)
  },
})
