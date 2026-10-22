---
name: analize_webrtc_dumps
description: Analiza volcados de texto o JSON de chrome://webrtc-internals (webrtc_internals_dump) integrando la observacion manual de audio provista por el usuario. Ejecuta un script de apoyo en Python para calcular KPIs de transporte (perdida de paquetes, jitter, concealment, RTT) y emite un diagnostico de causa raiz para arquitecturas WebRTC con Kamailio o RTPEngine. Usar cuando el usuario entregue un archivo webrtc_internals_dump, reporte mala calidad de audio en llamadas WebRTC, o pida diagnosticar cortes, voz robotica o perdida de paquetes en una sesion de voz.
---

# WebRTC Internals Analyzer

Habilidad para procesar volcados de telemetría WebRTC, cruzar los datos de red con los hallazgos de audio reportados manualmente por el usuario y entregar un diagnóstico de causa raíz.

## When to Use

- El usuario entrega un archivo de diagnóstico `webrtc_internals_dump` (.txt o .json).
- El usuario reporta manualmente qué canal de audio está afectado (`input` de micrófono o `output` recibido).
- Se requiere auditar la calidad del flujo WebRTC hacia Kamailio o RTPEngine sin decodificar archivos WAV directamente.

## Core Workflow

### 1. Recolección de entradas
Verificar o solicitar dos parámetros obligatorios:
1. **Archivo de métricas:** Archivo `webrtc_internals_dump` (.txt o .json).
2. **Contexto del audio afectado (indicado por el usuario):**
   - Canal local (`input.wav`): Micrófono con clipping, saturación o silencio en origen.
   - Canal remoto (`output.wav`): Cortes recibidos, voz robótica o silencios en la llegada.

### 2. Ejecución del script de análisis
El script auxiliar `analyze_webrtc_dump.py` está incluido en esta skill (misma carpeta que este SKILL.md). Ejecutarlo localmente pasando la ruta del archivo de volcado:

```bash
python analyze_webrtc_dump.py <ruta_del_dump>
```

El script imprimirá un JSON con las métricas calculadas:
- `loss_percentage`: Porcentaje de pérdida de paquetes RTP.
- `concealment_percentage`: Porcentaje de muestras reconstruidas por PLC.
- `jitter_ms`: Jitter en milisegundos.
- `rtt_ms`: Latencia RTT estimada contra RTPEngine.
- `fec_enabled`: Si `useinbandfec=1` está habilitado en el SDP.
- `codec`: Códec negociado en la sesión.

### 3. Matriz de Correlación Diagnóstica

Cruzar la salida del script con el audio reportado por el usuario:

| Audio reportado por el usuario | Métrica del script | Diagnóstico de causa raíz |
| :--- | :--- | :--- |
| `input.wav` defectuoso | Pérdida = 0%, PLC = 0% | Problema local de hardware, ganancia de micrófono o configuración del SO. Red descartada. |
| `output.wav` defectuoso | `loss_percentage > 3%` | Pérdida de paquetes en el enlace IP entre RTPEngine y el cliente. |
| `output.wav` robótico/metálico | `concealment_percentage > 2%`, Pérdida baja | Jitter elevado que desborda el jitter buffer de Chrome, forzando descartes de paquetes. |
| `output.wav` entrecortado | `fec_enabled = False` | Opus no tiene redundancia activa en el SDP (`useinbandfec=1` ausente); no compensa micro-cortes. |
| `output.wav` con baja fidelidad | `codec = G.711` | Transcodificación forzada o indeseada en Kamailio / RTPEngine en lugar de mantener Opus full-band. |

### 4. Formato de Salida

Generar la respuesta final bajo la siguiente estructura:

1. **Veredicto:** Estado de la llamada y causa principal en 1 párrafo conciso.
2. **Tabla de KPIs Técnicos:**
   - Pérdida de paquetes (Objetivo: < 1.0%)
   - Tasa de Ocultamiento / PLC (Objetivo: < 1.0%)
   - Jitter (Objetivo: < 30 ms)
   - RTT (Objetivo: < 150 ms)
   - Opus FEC (Estado de `useinbandfec=1`)
3. **Correlación con el audio del usuario:** Explicación técnica de la relación entre el canal fallido (`input` u `output`) y los datos analizados.
4. **Acciones recomendadas:** Soluciones concretas a nivel de red, SDP en Kamailio o configuración de RTPEngine.
