import std/[unittest, bitops, sets]
import cairn/[planner, damage, store, prng]

proc synthetic(masks: seq[uint64]; n, k: int): DamageReport =
  for mask in masks:
    var obj = ObjectDamage(id: $mask, total: n, required: k, state: rvHealthy)
    for index in 0..<n:
      let good = (mask and (1'u64 shl index)) != 0
      obj.slots.add PacketStatus(index: index, state: if good: psGood else: psMissing)
      if good: inc obj.good
    if obj.good < k: obj.state = rvLost
    elif obj.good < n: obj.state = rvDegraded
    result.objects.add obj

proc oracle(report: DamageReport; costs: seq[int64]): int64 =
  result = high(int64)
  for mask in 0'u64..<(1'u64 shl costs.len):
    var valid = true
    for obj in report.objects:
      var count = 0
      for slot in obj.slots:
        if slot.state == psGood and (mask and (1'u64 shl slot.index)) != 0: inc count
      if count < obj.required: valid = false
    if valid:
      var cost = 0'i64
      for i, value in costs:
        if (mask and (1'u64 shl i)) != 0: cost += value
      result = min(result, cost)

suite "weighted recovery media selection":
  test "randomized plans match independent exhaustive subset oracle":
    var rng = Prng(state: 101)
    for trial in 0..<300:
      let n = rng.bounded(7)+2
      let k = rng.bounded(n-1)+1
      var masks: seq[uint64]
      for obj in 0..<rng.bounded(8)+1:
        var mask = rng.next and ((1'u64 shl n)-1)
        while countSetBits(mask) < k: mask = mask or (1'u64 shl rng.bounded(n))
        masks.add mask
      let report = synthetic(masks, n, k)
      var costs: seq[int64]
      for index in 0..<n: costs.add int64(rng.bounded(20))
      let plan = planRecovery(report, costs)
      check plan.feasible
      check plan.optimal
      check plan.cost == oracle(report, costs)
      let selected = plan.volumes.toHashSet
      for obj in report.objects:
        var count = 0
        for slot in obj.slots:
          if slot.state == psGood and slot.index in selected: inc count
        check count >= k
  test "state exhaustion preserves a feasible plan and discloses uncertainty":
    let report = synthetic(@[0b11101'u64, 0b11011'u64, 0b10111'u64], 5, 3)
    let plan = planRecovery(report, @[1'i64, 2, 3, 4, 5], maxStates = 1)
    check plan.feasible
    check not plan.optimal
    check plan.lowerBound <= plan.cost
  test "impossible archives are not called recoverable":
    let plan = planRecovery(synthetic(@[0b0011'u64], 5, 3), @[1'i64, 1, 1, 1, 1])
    check not plan.feasible
    check plan.lostObjects.len == 1
