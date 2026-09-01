import Foundation

struct RFSharedChannelInput: Sendable {
    var linkID: String
    var linkKind: LogicalLinkKind
    var state: RFPacketDeliveryState
    var evaluation: RFLinkEvaluation
    var traffic: RFPacketTrafficProfile
}

struct RFSharedChannelStatistics: Equatable, Identifiable, Sendable {
    var transmitterDeviceID: String
    var capacityBPS: Double
    var requestedBitrateBPS: [LogicalLinkKind: Double]
    var reservedBitrateBPS: [LogicalLinkKind: Double]
    var allocatedBitrateBPS: [LogicalLinkKind: Double]
    var borrowedBitrateBPS: [LogicalLinkKind: Double]
    var backpressuredLinks: Set<LogicalLinkKind>
    var reservationBorrowingEnabled: Bool
    var dynamicControlBoostActive: Bool

    var id: String { transmitterDeviceID }

    var utilizedBitrateBPS: Double {
        allocatedBitrateBPS.values.reduce(0, +)
    }

    var utilizationRatio: Double {
        guard capacityBPS > 0 else { return 0 }
        return min(1, utilizedBitrateBPS / capacityBPS)
    }
}

struct RFSharedChannelOutput: Sendable {
    var states: [LogicalLinkKind: RFPacketDeliveryState]
    var statistics: RFSharedChannelStatistics
}

/// Reservation-aware scheduler for logical streams sharing one physical transmitter. Authored QoS
/// guarantees critical traffic first, distributes the unreserved pool by priority, and only lends
/// unused reservations to other streams when borrowing is explicitly enabled.
struct RFSharedChannelScheduler {
    var packetEngine = RFPacketDeliveryEngine()
    var mcsController = RFAdaptiveMCSController()

    func advance(
        transmitterDeviceID: String,
        inputs: [RFSharedChannelInput],
        channelCapacityBPS: Double? = nil,
        qos: RFQoSConfiguration = .migrationDefault,
        deltaTime: Double
    ) -> RFSharedChannelOutput {
        let safeDelta = max(0, deltaTime)
        let requested = Dictionary(uniqueKeysWithValues: inputs.map { input in
            (input.linkKind, requestedBitrate(for: input, deltaTime: safeDelta))
        })
        let derivedCapacity = inputs.map { input in
            let mcs = mcsController.select(for: input.evaluation)
            return max(0, input.evaluation.quality.effectiveBitrateBps) * mcs.bitrateMultiplier
        }.max() ?? 0
        let capacity = max(0, channelCapacityBPS ?? derivedCapacity)

        let sortedInputs = inputs.sorted { lhs, rhs in
            hasHigherPriority(lhs, than: rhs, qos: qos)
        }
        let boostActive = qos.dynamicReservationEnabled && inputs.contains { input in
            input.linkKind == .control
                && input.state.secondsSinceLastDelivery >= qos.controlBoostCommandAgeSeconds
        }
        let reservationTargets = Dictionary(uniqueKeysWithValues: inputs.map { input in
            let policy = qos.policy(for: input.linkKind)
            let multiplier = boostActive && input.linkKind == .control
                ? qos.controlBoostMultiplier
                : 1
            let shareLimit = capacity * max(0, min(1, policy.maximumShareFraction))
            return (
                input.linkKind,
                min(shareLimit, max(0, policy.minimumReservedBitrateBPS * multiplier))
            )
        })
        let maximumAllocations = Dictionary(uniqueKeysWithValues: inputs.map { input in
            let policy = qos.policy(for: input.linkKind)
            return (
                input.linkKind,
                capacity * max(0, min(1, policy.maximumShareFraction))
            )
        })

        var remainingBPS = capacity
        var allocations: [LogicalLinkKind: Double] = [:]
        for input in sortedInputs {
            let demand = requested[input.linkKind] ?? 0
            let reservation = reservationTargets[input.linkKind] ?? 0
            let allocation = min(demand, reservation, remainingBPS)
            allocations[input.linkKind] = allocation
            remainingBPS = max(0, remainingBPS - allocation)
        }

        // Capacity not assigned to any reservation is always a shared pool. It remains usable
        // even when reservation borrowing is disabled.
        var unreservedPoolBPS = min(
            remainingBPS,
            max(0, capacity - reservationTargets.values.reduce(0, +))
        )
        distribute(
            budgetBPS: &unreservedPoolBPS,
            physicalRemainingBPS: &remainingBPS,
            inputs: sortedInputs,
            requested: requested,
            maximumAllocations: maximumAllocations,
            allocations: &allocations
        )

        var borrowed: [LogicalLinkKind: Double] = [:]
        if qos.reservationBorrowingEnabled {
            let allocationsBeforeBorrowing = allocations
            var borrowingPoolBPS = remainingBPS
            distribute(
                budgetBPS: &borrowingPoolBPS,
                physicalRemainingBPS: &remainingBPS,
                inputs: sortedInputs,
                requested: requested,
                maximumAllocations: maximumAllocations,
                allocations: &allocations
            )
            for input in inputs {
                borrowed[input.linkKind] = max(
                    0,
                    (allocations[input.linkKind] ?? 0)
                        - (allocationsBeforeBorrowing[input.linkKind] ?? 0)
                )
            }
        }

        var states: [LogicalLinkKind: RFPacketDeliveryState] = [:]
        var backpressured: Set<LogicalLinkKind> = []
        for input in inputs {
            let allocation = allocations[input.linkKind] ?? 0
            let demand = requested[input.linkKind] ?? 0
            if demand - allocation > 0.5 {
                backpressured.insert(input.linkKind)
            }
            states[input.linkKind] = packetEngine.advance(
                input.state,
                linkID: input.linkID,
                traffic: input.traffic,
                deltaTime: safeDelta,
                evaluation: input.evaluation,
                transmissionBudgetBits: allocation * safeDelta
            )
        }

        return RFSharedChannelOutput(
            states: states,
            statistics: RFSharedChannelStatistics(
                transmitterDeviceID: transmitterDeviceID,
                capacityBPS: capacity,
                requestedBitrateBPS: requested,
                reservedBitrateBPS: reservationTargets,
                allocatedBitrateBPS: allocations,
                borrowedBitrateBPS: borrowed,
                backpressuredLinks: backpressured,
                reservationBorrowingEnabled: qos.reservationBorrowingEnabled,
                dynamicControlBoostActive: boostActive
            )
        )
    }

    private func distribute(
        budgetBPS: inout Double,
        physicalRemainingBPS: inout Double,
        inputs: [RFSharedChannelInput],
        requested: [LogicalLinkKind: Double],
        maximumAllocations: [LogicalLinkKind: Double],
        allocations: inout [LogicalLinkKind: Double]
    ) {
        for input in inputs where budgetBPS > 0 && physicalRemainingBPS > 0 {
            let current = allocations[input.linkKind] ?? 0
            let unmetDemand = max(0, (requested[input.linkKind] ?? 0) - current)
            let remainingShare = max(0, (maximumAllocations[input.linkKind] ?? 0) - current)
            let increment = min(unmetDemand, remainingShare, budgetBPS, physicalRemainingBPS)
            allocations[input.linkKind] = current + increment
            budgetBPS = max(0, budgetBPS - increment)
            physicalRemainingBPS = max(0, physicalRemainingBPS - increment)
        }
    }

    private func requestedBitrate(
        for input: RFSharedChannelInput,
        deltaTime: Double
    ) -> Double {
        let bitsPerPacket = Double(input.traffic.packetSizeBytes * 8 + 64)
        let offeredBPS = input.traffic.packetsPerSecond * bitsPerPacket
        let backlogBPS = deltaTime > 0
            ? Double(input.state.queueDepth) * bitsPerPacket / deltaTime
            : 0
        let mcs = mcsController.select(for: input.evaluation)
        let linkCeilingBPS = max(0, input.evaluation.quality.effectiveBitrateBps)
            * mcs.bitrateMultiplier
        return min(linkCeilingBPS, offeredBPS + backlogBPS)
    }

    private func hasHigherPriority(
        _ lhs: RFSharedChannelInput,
        than rhs: RFSharedChannelInput,
        qos: RFQoSConfiguration
    ) -> Bool {
        let lhsPriority = qos.policy(for: lhs.linkKind).priority
        let rhsPriority = qos.policy(for: rhs.linkKind).priority
        if lhsPriority == rhsPriority { return lhs.linkID < rhs.linkID }
        return lhsPriority < rhsPriority
    }
}
