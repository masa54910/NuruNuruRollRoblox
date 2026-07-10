# NuruNuruRoll Phase 0 Audit

## Scope
- Preserve existing generated course as-is.
- Separate course generation from legacy sled/slide runtime.
- No new slide/sled gameplay implementation.

## Findings

### Course generation source
- Main file: src/ServerScriptService/Server/MapBuilder.server.lua
- Startup trigger: script startup block guarded by expected full name and duplicate runner global.
- Root output hierarchy under Workspace:
  - NuruNuruRollMap/Course
  - NuruNuruRollMap/Lotion
  - NuruNuruRollMap/CourseWalls
  - NuruNuruRollMap/Start
  - NuruNuruRollMap/Goal
  - NuruNuruRollMap/Decorations
  - NuruNuruRollMap/Debug
- Ready signal: Workspace attribute NuruNuruRollMapReady

### Legacy movement systems
- Legacy disabled body slide placeholder:
  - src/ServerScriptService/Server/LotionSlideSystem.server.lua
- Legacy sled runtime (was active before Phase 0 edit):
  - src/ServerScriptService/Server/SledServerController.server.lua
  - src/StarterPlayer/StarterPlayerScripts/Client/SledInputClient.client.lua
  - src/ReplicatedStorage/Shared/Remotes.lua (SledInput)
  - src/ReplicatedStorage/Shared/Config.lua (Sled settings)

### Gameplay framework that remains reusable
- Goal/score trigger: src/ServerScriptService/Server/GoalSystem.server.lua
- Round loop and result publish: src/ServerScriptService/Server/ResultSystem.server.lua
- HUD/result clients:
  - src/StarterPlayer/StarterPlayerScripts/Client/SlideClient.client.lua
  - src/StarterPlayer/StarterPlayerScripts/Client/ResultClient.client.lua

## Phase 0 minimal separation change
- Added project flag: Config.Project.EnableLegacySledSystem = false
- Added runtime guard in SledServerController to exit early when flag is false.
- Effect: course generation remains active; legacy sled runtime does not start.

## Caution points for Phase 1
- GoalSystem currently accepts touches from character models and models carrying OwnerUserId. Keep this if new sled also uses model ownership attributes.
- MapBuilder has strict health checks and can fail if any required structure changes unexpectedly.
- Keep NuruNuruRollMapReady contract unchanged to avoid startup race regressions.
