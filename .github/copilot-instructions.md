# GitHub Copilot instructions for NuruNuruRoll

- This is a Roblox Studio project written in Luau and synchronized by Rojo.
- Read the surrounding implementation, `AGENTS.md`, and the relevant `docs/` page before suggesting code.
- Do not infer or redesign existing behavior from names alone. Clearly mark assumptions.
- Prefer localized edits. Do not rewrite whole files, rename symbols, format unrelated code, or reorganize folders unless requested.
- Keep Roblox client, server, and shared responsibilities separate. Client input and presentation are not server authority.
- Validate every client-to-server RemoteEvent or RemoteFunction request on the server: type, finite numeric value, range, rate, permission, distance, and current game state as applicable.
- Account for `CharacterAdded`, character removal, death, and `PlayerRemoving`. Disconnect owned events and ignore destroyed Instances.
- Guard optional Instance references and re-check parentage after yields.
- Keep per-frame work small. Cache stable references; avoid Workspace-wide scans and repeated allocations in frame callbacks.
- Use `task.wait`, `task.spawn`, and `task.delay` only when scheduling is needed. Do not introduce legacy `wait`, `spawn`, or `delay`.
- Put tunable values in the existing Config structure when the requested phase authorizes Config changes. Do not create duplicate magic-number systems.
- Show where code belongs and how it must be checked in Studio; code generation alone is not acceptance.
- Do not claim Play, physics, camera, or Rojo behavior was verified unless it was actually observed in Roblox Studio.

## Protected NuruNuruRoll design

- Preserve the established course. Do not change course coordinates, Road positions, `StartPad`, `CourseSpawn`, or `GoalTrigger`.
- Treat `MapBuilder.server.lua` as protected unless the task explicitly concerns map generation.
- Keep the Baseplate retirement logic and never return the Baseplate to the course.
- Preserve legacy systems as disabled by Config flags; do not delete them as cleanup.
- Implement one Phase 2 step at a time.
- Do not use `VehicleSeat`.
- Do not move the player with CFrame or Tween. Camera CFrame control is separate and may be used only in an authorized camera phase.
- Use `HumanoidRootPart` as the physical assembly for the intended body-sliding design, but do not combine competing primary movement controllers.
- Before changing physics, search for every writer of velocity, force, CFrame, Humanoid state, controls, and network ownership.
- Follow [`docs/10_ぬるぬるRoll固有設計.md`](../docs/10_ぬるぬるRoll固有設計.md) when general Roblox advice conflicts with project-specific constraints.

