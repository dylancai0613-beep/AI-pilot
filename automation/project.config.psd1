@{
    ProjectName = "Travel Cost Pilot"

    Agent = @{
        AdapterPath = "automation/adapters/agent/codex.ps1"
    }

    Validation = @{
        AdapterPath = "automation/adapters/validation/travel-cost.ps1"
        ReportPath = "automation/reports/validation-latest.txt"
    }

    Cleanup = @{
        Enabled = $true
        AdapterPath = "automation/adapters/cleanup/docker-compose.ps1"
    }

    Reports = @{
        Directory = "automation/reports"
        AutonomousLatest = "automation/reports/autonomous-latest.txt"
    }

    Defaults = @{
        MaxAttempts = 3
    }
}
