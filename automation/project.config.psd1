@{
    ProjectName = "Travel Cost Pilot"

    Agents = @{
        Developer = @{
            AdapterPath = "automation/adapters/agent/codex.ps1"

            Runtime = @{
                Name = "codex"
            }

            Model = @{
                Name = $null
                Reasoning = $null
            }

            Options = @{
                Sandbox = "workspace-write"
            }
        }

        Reviewer = @{
            Enabled = $true
            AdapterPath = "automation/adapters/agent/codex.ps1"

            Runtime = @{
                Name = "codex"
            }

            Model = @{
                Name = $null
                Reasoning = $null
            }

            Options = @{
                Sandbox = "workspace-write"
            }
        }
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

    Runs = @{
        Directory = "automation/runs"
    }

    Defaults = @{
        MaxAttempts = 3
        MaxReviewCycles = 2
        MaxReviewerAttempts = 2
    }
}
