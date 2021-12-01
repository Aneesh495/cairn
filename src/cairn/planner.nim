## Minimum-cost recovery media selection. Each object contributes a multicover
## constraint: at least k selected volumes must contain valid shards. A greedy
## feasible solution seeds a bounded branch-and-bound search. Exhausting the
## state budget leaves a useful plan with an explicit unproven optimality flag.
import std/[algorithm, bitops, json, sets]
import cairn/[damage, errors, store]

type
  RecoveryPlan* = object
    feasible*: bool
    optimal*: bool
    volumes*: seq[int]
    cost*: int64
    lowerBound*: int64
    explored*: int
    constraints*: int
    lostObjects*: seq[string]
  Constraint = object
    mask: uint64
    required: int

proc contains(mask: uint64; index: int): bool = (mask and (1'u64 shl index)) != 0

proc satisfied(constraints: seq[Constraint]; selected: uint64): bool =
  for constraint in constraints:
    if countSetBits(constraint.mask and selected) < constraint.required: return false
  true

proc maskCost(mask: uint64; costs: seq[int64]): int64 =
  for i, cost in costs:
    if mask.contains(i): result += cost

proc cheapestBound(constraints: seq[Constraint]; selected, remaining: uint64;
                   order: seq[int]; costs: seq[int64]): int64 =
  for constraint in constraints:
    var deficit = constraint.required - countSetBits(constraint.mask and selected)
    if deficit <= 0: continue
    var cost = 0'i64
    for index in order:
      if remaining.contains(index) and constraint.mask.contains(index):
        cost += costs[index]
        dec deficit
        if deficit == 0: break
    if deficit > 0: return high(int64)
    result = max(result, cost)

proc planRecovery*(report: DamageReport; costs: seq[int64]; maxStates = 1_000_000): RecoveryPlan =
  ## Return a feasible media set and a separately stated optimality result.
  ## Exhausting the state budget preserves the upper bound, not a proof.
  require(costs.len in 2..32 and maxStates > 0, ekInvalid, "invalid recovery planner dimensions")
  for cost in costs:
    require(cost >= 0 and cost <= 1_000_000_000, ekInvalid, "volume costs must be in 0..1000000000")
  var constraints: seq[Constraint]
  var unique = initHashSet[tuple[mask: uint64; required: int]]()
  for obj in report.objects:
    require(obj.total == costs.len, ekInvalid, "volume costs differ from archive geometry")
    if obj.state == rvLost:
      result.lostObjects.add obj.id
      continue
    var mask = 0'u64
    for slot in obj.slots:
      if slot.state == psGood: mask = mask or (1'u64 shl slot.index)
    let key = (mask, obj.required)
    if key notin unique:
      unique.incl key
      constraints.add Constraint(mask: mask, required: obj.required)
  result.constraints = constraints.len
  if result.lostObjects.len > 0:
    result.optimal = true
    return
  result.feasible = true
  var order: seq[int]
  for index in 0..<costs.len: order.add index
  order.sort(proc(a, b: int): int =
    result = cmp(costs[a], costs[b])
    if result == 0: result = cmp(a, b))
  let all = (1'u64 shl costs.len)-1
  var best = all
  # Remove expensive redundant media to get an initial feasible upper bound.
  for i in countdown(order.high, 0):
    let without = best and not (1'u64 shl order[i])
    if satisfied(constraints, without): best = without
  var bestCost = maskCost(best, costs)
  let rootBound = cheapestBound(constraints, 0, all, order, costs)
  var suffix = newSeq[uint64](order.len+1)
  for i in countdown(order.high, 0): suffix[i] = suffix[i+1] or (1'u64 shl order[i])
  var explored = 0
  var truncated = false
  proc search(at: int; selected: uint64; cost: int64) =
    if explored >= maxStates:
      truncated = true
      return
    inc explored
    if cost > bestCost: return
    if satisfied(constraints, selected):
      if cost < bestCost or (cost == bestCost and
          (countSetBits(selected) < countSetBits(best) or
           (countSetBits(selected) == countSetBits(best) and selected < best))):
        best = selected
        bestCost = cost
      return
    if at == order.len: return
    let bound = cheapestBound(constraints, selected, suffix[at], order, costs)
    if bound == high(int64) or bound > bestCost-cost: return
    let index = order[at]
    search(at+1, selected or (1'u64 shl index), cost+costs[index])
    search(at+1, selected, cost)
  search(0, 0, 0)
  result.optimal = not truncated
  result.cost = bestCost
  result.lowerBound = if result.optimal: bestCost else: rootBound
  result.explored = explored
  for index in 0..<costs.len:
    if best.contains(index): result.volumes.add index

proc toJson*(plan: RecoveryPlan): JsonNode =
  %*{"feasible": plan.feasible, "optimal": plan.optimal, "volumes": plan.volumes,
    "cost": plan.cost, "lower_bound": plan.lowerBound, "explored_states": plan.explored,
    "distinct_constraints": plan.constraints, "lost_objects": plan.lostObjects}
