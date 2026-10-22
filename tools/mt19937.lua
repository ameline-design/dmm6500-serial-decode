-- tools/mt19937.lua -- A SHIM. The implementation is bench/plan_rand.tsp.
--
-- WHY IT MOVED. The bench app draws its own soak plan now, so this generator has to be inside the
-- .tspa. It could not be copied there: the whole reason an on-instrument draw is trustworthy is that
-- tools/test_soakrand.py holds this code to CPython's own sequence, and a copy would leave that proof
-- attached to the file nobody runs. So the code lives in bench/ and this file points at it.
--
-- WHY THE FILE STAYS. tools/test_soakrand.py reaches the module through `require 'mt19937'` in two of
-- its checks, and that is the spelling a host caller expects. The sequence checks read
-- bench/plan_rand.tsp directly -- they send it to the instrument, which has no dofile and no tools/.
--
-- The archive cannot take this file as it stands, which is the other half of why the split exists: a
-- top-level `return` in a module would end the CONCATENATED chunk and every module after it would
-- never load.

local function try(p)
  local chunk = loadfile(p)
  if chunk == nil then return false end
  chunk()
  return true
end

if not (try('bench/plan_rand.tsp') or try('../bench/plan_rand.tsp')) then
  error('mt19937: cannot find bench/plan_rand.tsp -- run from the repository root', 2)
end

local M = bplan.mt

return M
