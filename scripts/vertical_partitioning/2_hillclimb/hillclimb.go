// Hankins and Patel, "Data Morphing: An Adaptive, Cache-Conscious Storage Technique" (VLDB 2003)
package hillclimb

import (
	"math"
	"slices"

	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

type QueryAccess struct {
	QueryName        string
	QueryFrequency   float64
	QueryAccessRates []float64
}

func QueryAccesses(entity workload.Entity, attributes []workload.Attribute, workloadName string) []QueryAccess {
	var queryAccesses []QueryAccess
	for _, transaction := range workload.Transactions {
		for _, access := range transaction.TransactionAccesses {
			if access.EntityName != entity.EntityName {
				continue
			}

			selectedProportion := access.AccessedRecords / entity.EntityCardinality
			queryAccessRates := make([]float64, len(attributes))
			attributeIsUsed := false
			for attributeIndex, attribute := range attributes {
				switch {
				case access.RestrictsAttribute(attribute.AttributeName):
					queryAccessRates[attributeIndex] = max(access.ExaminedRecords/entity.EntityCardinality, selectedProportion)
				case access.UsesAttribute(attribute.AttributeName):
					queryAccessRates[attributeIndex] = selectedProportion
				default:
					continue
				}
				attributeIsUsed = true
			}
			if !attributeIsUsed {
				continue
			}

			queryAccesses = append(queryAccesses, QueryAccess{
				QueryName:        transaction.TransactionName,
				QueryFrequency:   transaction.TransactionWeights[workloadName],
				QueryAccessRates: queryAccessRates,
			})
		}
	}

	return queryAccesses
}

func GroupCost(queryAccesses []QueryAccess, attributeBytes []float64, group []int, cacheLineBytes float64) float64 {
	var groupCost float64
	for _, queryAccess := range queryAccesses {
		groupCost += queryAccess.QueryFrequency * cacheMisses(queryAccess, attributeBytes, group, cacheLineBytes)
	}

	return groupCost
}

func cacheMisses(queryAccess QueryAccess, attributeBytes []float64, group []int, cacheLineBytes float64) float64 {
	var accessRate, groupBytes float64
	for _, attribute := range group {
		accessRate = max(accessRate, queryAccess.QueryAccessRates[attribute])
		groupBytes += attributeBytes[attribute]
	}
	if accessRate == 0 {
		return 0
	}

	recordsPerCacheLine := cacheLineBytes / groupBytes
	if recordInterval := 1 / accessRate; recordInterval < recordsPerCacheLine {
		return 1 / recordsPerCacheLine
	}

	return accessRate * math.Ceil(1/recordsPerCacheLine)
}

func PartitionCost(queryAccesses []QueryAccess, attributeBytes []float64, partition [][]int, cacheLineBytes float64) float64 {
	var partitionCost float64
	for _, group := range partition {
		partitionCost += GroupCost(queryAccesses, attributeBytes, group, cacheLineBytes)
	}

	return partitionCost
}

func HillClimb(queryAccesses []QueryAccess, attributeBytes []float64, cacheLineBytes float64) [][]int {
	partition := make([][]int, len(attributeBytes))
	for attribute := range partition {
		partition[attribute] = []int{attribute}
	}
	partitionCost := PartitionCost(queryAccesses, attributeBytes, partition, cacheLineBytes)

	for {
		bestCandidate, bestCost := [][]int(nil), math.Inf(1)
		for firstGroup := range partition {
			for secondGroup := firstGroup + 1; secondGroup < len(partition); secondGroup++ {
				candidate := mergedPartition(partition, firstGroup, secondGroup)
				if candidateCost := PartitionCost(queryAccesses, attributeBytes, candidate, cacheLineBytes); candidateCost < bestCost {
					bestCandidate, bestCost = candidate, candidateCost
				}
			}
		}
		if bestCandidate == nil || isCostlier(bestCost, partitionCost) {
			return partition
		}

		partition, partitionCost = bestCandidate, bestCost
	}
}

func isCostlier(cost, otherCost float64) bool {
	return cost > otherCost*(1+1e-9)
}

func mergedPartition(partition [][]int, firstGroup, secondGroup int) [][]int {
	var merged [][]int
	for groupIndex, group := range partition {
		switch groupIndex {
		case firstGroup:
			merged = append(merged, slices.Sorted(slices.Values(slices.Concat(group, partition[secondGroup]))))
		case secondGroup:
		default:
			merged = append(merged, group)
		}
	}

	return merged
}

func Naive(queryAccesses []QueryAccess, attributeBytes []float64, cacheLineBytes float64) [][]int {
	bestPartition, bestCost := [][]int(nil), math.Inf(1)
	for _, partition := range everyPartition(len(attributeBytes)) {
		partitionCost := PartitionCost(queryAccesses, attributeBytes, partition, cacheLineBytes)
		if isCostlier(bestCost, partitionCost) || !isCostlier(partitionCost, bestCost) && len(partition) < len(bestPartition) {
			bestPartition, bestCost = partition, partitionCost
		}
	}

	return bestPartition
}

func everyPartition(attributeCount int) [][][]int {
	partitions := [][][]int{{}}
	for attribute := range attributeCount {
		var extendedPartitions [][][]int
		for _, partition := range partitions {
			for groupIndex := range partition {
				extended := cloneGroups(partition)
				extended[groupIndex] = append(extended[groupIndex], attribute)
				extendedPartitions = append(extendedPartitions, extended)
			}
			extendedPartitions = append(extendedPartitions, append(cloneGroups(partition), []int{attribute}))
		}
		partitions = extendedPartitions
	}

	return partitions
}

func cloneGroups(groups [][]int) [][]int {
	cloned := make([][]int, len(groups))
	for groupIndex, group := range groups {
		cloned[groupIndex] = slices.Clone(group)
	}

	return cloned
}
