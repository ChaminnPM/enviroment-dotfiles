# PSScriptAnalyzerSettings.psd1 - reglas para la capa PowerShell.
#
# CI bloquea solo por Severity Error (ver .github/workflows/ci.yml); los
# avisos se listan pero no rompen el build. Las desactivaciones estan
# justificadas debajo.

@{
    Severity = @('Error', 'Warning')

    Rules = @{
        # Los modulos de UI escriben a consola con Write-Host a proposito: si
        # usaran Write-Output, la salida contaminaria el valor de retorno de
        # las funciones (los codigos de salida de los pasos).
        PSAvoidUsingWriteHost = @{
            Enable = $false
        }

        # El snippet de oh-my-posh que se escribe en $PROFILE es el modo
        # oficial del upstream (Invoke-Expression sobre su propio init).
        PSAvoidUsingInvokeExpression = @{
            Enable = $false
        }

        # WMI no se usa, pero Get-CimInstance tampoco: la informacion de SO se
        # lee del runtime de .NET.
        PSAvoidUsingWMICmdlet = @{
            Enable = $false
        }

        # Los helpers de UI/Pester declaran variables de contexto que se usan
        # en otros bloques (BeforeAll -> It) que el analizador estatico no ve.
        PSUseDeclaredVarsMoreThanAssignments = @{
            Enable = $false
        }

        # Nombres en plural coherentes con el resto del repo (Paths, Themes).
        PSUseSingularNouns = @{
            Enable = $false
        }

        # Los instaladores no tienen SupportsShouldProcess: el control de
        # ejecucion es el panel (-DryRun / -NonInteractive), no -WhatIf.
        PSUseShouldProcessForStateChangingFunctions = @{
            Enable = $false
        }

        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }

        PSUseConsistentWhitespace = @{
            Enable          = $true
            CheckOpenBrace  = $true
            CheckOpenParen  = $true
            CheckCloseBrace = $true
            CheckOperator   = $true
            CheckSeparator  = $true
            CheckComma      = $false
        }

        PSAvoidTrailingWhitespace = @{
            Enable = $true
        }

        PSAvoidGlobalVars = @{
            Enable = $true
        }

        PSPossibleIncorrectComparisonWithNull = @{
            Enable = $true
        }

        PSAvoidUsingPosition = @{
            Enable = $true
        }

        PSAvoidUsingCmdletAliases = @{
            Enable         = $true
            AllowCommonParameters = $true
        }

        # Credenciales: el instalador no pide contrasenas en Windows (no hay
        # sudo); Read-Host -AsSecureString se usa donde hace falta.
        PSAvoidUsingPlainTextForPassword = @{
            Enable = $true
        }

        PSUseApprovedVerbs = @{
            Enable = $true
        }
    }
}
