#!/usr/bin/env python3
import json
import re
import sys
import os

def extract_latest_val(series):
    """Extrae el último valor numérico válido de una serie temporal de Chrome internals."""
    if not series:
        return 0.0
    if isinstance(series, list):
        # En dumps de Chrome, los arrays suelen alternar [timestamp, valor, ...] o ser listas de valores
        for item in reversed(series):
            try:
                return float(item)
            except (ValueError, TypeError):
                continue
    elif isinstance(series, (int, float)):
        return float(series)
    elif isinstance(series, str):
        try:
            return float(series.strip('"'))
        except ValueError:
            return 0.0
    return 0.0

def analyze_dump(file_path):
    if not os.path.exists(file_path):
        print(f"Error: Archivo no encontrado en {file_path}")
        sys.exit(1)

    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Intentar parsear como JSON estructurado
    data = None
    try:
        data = json.loads(content)
    except Exception:
        pass

    results = {
        "packetsReceived": 0,
        "packetsLost": 0,
        "concealedSamples": 0,
        "totalSamplesReceived": 0,
        "jitter_ms": 0.0,
        "rtt_ms": 0.0,
        "fec_enabled": False,
        "codec_detected": "Desconocido"
    }

    if isinstance(data, dict):
        # Búsqueda estructurada dentro del JSON de WebRTC internals
        for pc_id, pc_data in data.items():
            if not isinstance(pc_data, dict):
                continue

            # Revisión de SDP / Códec
            sdp_history = pc_data.get("updateLog", [])
            for entry in sdp_history:
                sdp_text = str(entry.get("value", ""))
                if "useinbandfec=1" in sdp_text:
                    results["fec_enabled"] = True
                if "opus/48000" in sdp_text.lower():
                    results["codec_detected"] = "Opus"
                elif "pcmu" in sdp_text.lower() or "pcma" in sdp_text.lower():
                    results["codec_detected"] = "G.711 (PCMU/PCMA)"

            # Estadísticas RTC
            stats = pc_data.get("stats", {})
            for stat_id, stat_obj in stats.items():
                values = stat_obj.get("values", {})
                if not isinstance(values, dict):
                    continue

                if "packetsReceived" in values:
                    results["packetsReceived"] = int(extract_latest_val(values["packetsReceived"]))
                if "packetsLost" in values:
                    results["packetsLost"] = int(extract_latest_val(values["packetsLost"]))
                if "concealedSamples" in values:
                    results["concealedSamples"] = int(extract_latest_val(values["concealedSamples"]))
                if "totalSamplesReceived" in values:
                    results["totalSamplesReceived"] = int(extract_latest_val(values["totalSamplesReceived"]))
                if "jitter" in values:
                    results["jitter_ms"] = extract_latest_val(values["jitter"]) * 1000.0
                if "currentRoundTripTime" in values:
                    results["rtt_ms"] = extract_latest_val(values["currentRoundTripTime"]) * 1000.0

    # Fallback vía Regex si el dump no es JSON válido o es formato plano de texto
    if results["packetsReceived"] == 0 and results["totalSamplesReceived"] == 0:
        for metric in ["packetsReceived", "packetsLost", "concealedSamples", "totalSamplesReceived"]:
            matches = re.findall(rf'"{metric}"\s*:\s*\[?([^,\n\]]+)', content)
            if matches:
                try:
                    results[metric] = int(float(matches[-1].strip('"')))
                except ValueError:
                    pass

        jitter_matches = re.findall(r'"jitter"\s*:\s*\[?([^,\n\]]+)', content)
        if jitter_matches:
            results["jitter_ms"] = float(jitter_matches[-1].strip('"')) * 1000.0

        rtt_matches = re.findall(r'"currentRoundTripTime"\s*:\s*\[?([^,\n\]]+)', content)
        if rtt_matches:
            results["rtt_ms"] = float(rtt_matches[-1].strip('"')) * 1000.0

        if "useinbandfec=1" in content:
            results["fec_enabled"] = True
        if "opus/48000" in content.lower():
            results["codec_detected"] = "Opus"

    # Cálculo de métricas derivadas
    total_expected = results["packetsLost"] + results["packetsReceived"]
    loss_rate = (results["packetsLost"] / total_expected * 100.0) if total_expected > 0 else 0.0

    conceal_rate = (
        (results["concealedSamples"] / results["totalSamplesReceived"] * 100.0)
        if results["totalSamplesReceived"] > 0 else 0.0
    )

    output = {
        "raw_metrics": results,
        "kpis": {
            "loss_percentage": round(loss_rate, 2),
            "concealment_percentage": round(conceal_rate, 2),
            "jitter_ms": round(results["jitter_ms"], 2),
            "rtt_ms": round(results["rtt_ms"], 2),
            "fec_enabled": results["fec_enabled"],
            "codec": results["codec_detected"]
        }
    }

    print(json.dumps(output, indent=2))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Uso: python analyze_webrtc_dump.py <ruta_archivo_dump>")
        sys.exit(1)
    analyze_dump(sys.argv[1])