import { Plugin } from "@opencode/plugin"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"

const CACHE_TTL = 5 * 60 * 1000
const MICROCENTS_PER_DOLLAR = 100_000_000

function cacheFile(): string {
  const dir = path.join(os.homedir(), ".cache", "opencode")
  try { fs.mkdirSync(dir, { recursive: true }) } catch {}
  return path.join(dir, "usage-limits.json")
}

function toUsd(microcents: any): number {
  if (microcents === null || microcents === undefined) return 0
  const n = typeof microcents === "string" ? Number(microcents) : microcents
  if (!Number.isFinite(n)) return 0
  return n / MICROCENTS_PER_DOLLAR
}

function meterWindow(m: any): any {
  const used = toUsd(m?.usedMicroCents)
  const limit = toUsd(m?.limitMicroCents)
  const percent = limit > 0 ? (used / limit) * 100 : 0
  return { usedUsd: used, limitUsd: limit, percent, startsAt: m?.startsAt, resetsAt: m?.resetsAt }
}

async function fetchAll(signal: AbortSignal, token: string, orgId: string): Promise<any> {
  const headers: Record<string, string> = { Authorization: `Bearer ${token}`, Accept: "application/json" }
  if (orgId) headers["x-org-id"] = orgId
  const base = "https://opencode.ai/console/api"
  const [goRes, billingRes, summaryRes] = await Promise.all([
    fetch(`${base}/go/status`, { headers, signal }),
    fetch(`${base}/billing/status`, { headers, signal }),
    fetch(`${base}/usage/summary?range=30d`, { headers, signal }),
  ])

  const out: any = { fetchedAt: new Date().toISOString() }

  if (goRes.ok) {
    const go = (await goRes.json()) as any
    const access = go?.access || {}
    const meters = access.meters || {}
    out.go = {
      product: go.product,
      renewalProduct: go.renewalProduct,
      startsAt: access.startsAt,
      endsAt: access.endsAt,
      cancelAtPeriodEnd: access.cancelAtPeriodEnd,
      fiveHour: meterWindow(meters.fiveHour),
      week: meterWindow(meters.week),
      month: meterWindow(meters.month),
    }
  } else {
    out.error = `Go status: HTTP ${goRes.status}`
  }

  if (billingRes.ok) {
    const b = (await billingRes.json()) as any
    out.zen = {
      mode: b.mode,
      billingMode: b.billingMode,
      balanceUsd: toUsd(b.balanceMicroCents),
      availableUsd: toUsd(b.availableMicroCents),
      creditLimitUsd: b.creditLimitMicroCents === null || b.creditLimitMicroCents === undefined ? null : toUsd(b.creditLimitMicroCents),
    }
  } else if (!out.error) {
    out.error = `Billing status: HTTP ${billingRes.status}`
  }

  if (summaryRes.ok) {
    const s = (await summaryRes.json()) as any
    out.summary30d = {
      requests: Number(s.totalRequests) || 0,
      inputTokens: Number(s.totalInputTokens) || 0,
      outputTokens: Number(s.totalOutputTokens) || 0,
      cacheReadTokens: Number(s.totalCacheReadTokens) || 0,
      costUsd: toUsd(s.totalCostMicroCents),
    }
  }

  return out
}

async function resolveConsole(ctx: any): Promise<{ token: string; orgId: string } | null> {
  try {
    const conn = await ctx.integration.connection.active("opencode")
    if (!conn) return null
    const cred: any = await ctx.integration.connection.resolve(conn)
    if (!cred) return null
    const token = cred.access || cred.value?.access || cred.token
    const orgId = cred.metadata?.orgID || cred.metadata?.orgId || cred.value?.metadata?.orgID || ""
    if (!token) return null
    return { token, orgId }
  } catch {
    return null
  }
}

function writeCache(data: any): void {
  try { fs.writeFileSync(cacheFile(), JSON.stringify(data)) } catch {}
}

function readCache(): any {
  try { return JSON.parse(fs.readFileSync(cacheFile(), "utf8")) } catch { return null }
}

function formatText(data: any): string {
  if (!data) return "No data."
  if (data.error) return `⚠ ${data.error}`
  const lines: string[] = []
  const go = data.go
  if (go) {
    lines.push(`Go (${go.product ?? "go"}) — renueva ${go.endsAt ?? ""}`)
    const w = (label: string, m: any) => {
      if (!m) return
      lines.push(`  ${label}: $${m.usedUsd.toFixed(2)} / $${m.limitUsd.toFixed(2)}  ${m.percent.toFixed(1)}%`)
      lines.push(`     ${m.resetsAt ? "reinicia: " + m.resetsAt : ""}`)
    }
    w("5h   ", go.fiveHour)
    w("Semana", go.week)
    w("Mes   ", go.month)
  }
  const zen = data.zen
  if (zen) {
    lines.push("")
    lines.push("Zen (pay-as-you-go)")
    lines.push(`  Balance: $${zen.balanceUsd.toFixed(2)}`)
    if (zen.creditLimitUsd !== null && zen.creditLimitUsd !== undefined) lines.push(`  Límite mensual: $${zen.creditLimitUsd.toFixed(2)}`)
  }
  const s = data.summary30d
  if (s) {
    lines.push("")
    lines.push("Últimos 30 días")
    lines.push(`  Requests: ${s.requests}  Coste: $${s.costUsd.toFixed(2)}`)
  }
  return lines.join("\n")
}

export default Plugin.define({
  id: "usage-limits",
  async setup(ctx) {
    let timer: any = null

    const refresh = async (signal?: AbortSignal) => {
      const resolved = await resolveConsole(ctx)
      if (!resolved) {
        const data = { error: "Sign in to OpenCode Console with /connect (OpenCode Console).", fetchedAt: new Date().toISOString() }
        writeCache(data)
        return data
      }
      try {
        const data = await fetchAll(signal || (new AbortController()).signal, resolved.token, resolved.orgId)
        writeCache(data)
        return data
      } catch (e: any) {
        const data = { error: e?.message || "Failed to fetch usage.", fetchedAt: new Date().toISOString() }
        writeCache(data)
        return data
      }
    }

    await refresh()

    timer = setInterval(() => { void refresh() }, CACHE_TTL)

    await ctx.tool.transform((editor) => {
      editor.namespace({ name: "usage", description: "OpenCode Go/Zen usage limits" })
      editor.add({
        name: "limits",
        description: "Fetch current OpenCode Go and Zen usage limits.",
        input: { type: "object", properties: {}, additionalProperties: false },
        options: { namespace: "usage", codemode: true },
        execute: async () => {
          const data = readCache() || (await refresh())
          return { content: formatText(data) }
        },
      })
    })

    return () => {
      if (timer) clearInterval(timer)
    }
  },
})
