// Papadomanolakis and Ailamaki, "AutoPart: Automating Schema Design for Large Scientific Databases Using Data Partitioning" (SSDBM 2004)
package autopart

import (
	"math"
	"slices"

	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

type QueryAccessSet struct {
	QueryName       string
	QueryFrequency  float64
	QueryAttributes []int
}

type PartitioningParameters struct {
	ScanScalingFactor  float64
	FragmentJoinCost   float64
	ReplicationBudget  float64
	MinimumQueryExtent int
}

func QueryAccessSets(entity workload.Entity, attributes []workload.Attribute, workloadName string) []QueryAccessSet {
	var queryAccessSets []QueryAccessSet
	for _, transaction := range workload.Transactions {
		for _, access := range transaction.TransactionAccesses {
			if access.EntityName != entity.EntityName {
				continue
			}

			var queryAttributes []int
			for attributeIndex, attribute := range attributes {
				if access.UsesAttribute(attribute.AttributeName) {
					queryAttributes = append(queryAttributes, attributeIndex)
				}
			}
			if len(queryAttributes) == 0 {
				continue
			}

			queryAccessSets = append(queryAccessSets, QueryAccessSet{
				QueryName:       transaction.TransactionName,
				QueryFrequency:  transaction.TransactionWeights[workloadName],
				QueryAttributes: queryAttributes,
			})
		}
	}

	return queryAccessSets
}

func AtomicFragments(queryAccessSets []QueryAccessSet, attributeCount int) [][]int {
	var atomicFragments [][]int
	var fragmentQueries [][]int
	for attribute := range attributeCount {
		var attributeQueries []int
		for queryIndex, queryAccessSet := range queryAccessSets {
			if slices.Contains(queryAccessSet.QueryAttributes, attribute) {
				attributeQueries = append(attributeQueries, queryIndex)
			}
		}

		fragmentIndex := slices.IndexFunc(fragmentQueries, func(queries []int) bool { return slices.Equal(queries, attributeQueries) })
		if fragmentIndex < 0 {
			atomicFragments = append(atomicFragments, nil)
			fragmentQueries = append(fragmentQueries, attributeQueries)
			fragmentIndex = len(atomicFragments) - 1
		}
		atomicFragments[fragmentIndex] = append(atomicFragments[fragmentIndex], attribute)
	}

	return atomicFragments
}

func Partitioning(queryAccessSets []QueryAccessSet, attributeBytes []float64, partitioningParameters PartitioningParameters) [][]int {
	atomicFragments := AtomicFragments(queryAccessSets, len(attributeBytes))
	partialSolution := cloneFragments(atomicFragments)
	partialCost := WorkloadCost(queryAccessSets, partialSolution, partitioningParameters)

	selectedFragments := cloneFragments(atomicFragments)
	for len(selectedFragments) > 0 {
		compositeFragments := generateCompositeFragments(queryAccessSets, atomicFragments, selectedFragments, partitioningParameters.MinimumQueryExtent)

		selectedFragments = nil
		for {
			bestFragment, bestSolution, bestCost := -1, [][]int(nil), partialCost
			for fragmentIndex, compositeFragment := range compositeFragments {
				candidateSolution := addFragment(partialSolution, compositeFragment)
				if replicatedBytes(candidateSolution, attributeBytes) > partitioningParameters.ReplicationBudget*total(attributeBytes) {
					continue
				}

				if candidateCost := WorkloadCost(queryAccessSets, candidateSolution, partitioningParameters); candidateCost < bestCost {
					bestFragment, bestSolution, bestCost = fragmentIndex, candidateSolution, candidateCost
				}
			}
			if bestFragment < 0 {
				break
			}

			partialSolution, partialCost = bestSolution, bestCost
			selectedFragments = append(selectedFragments, compositeFragments[bestFragment])
			compositeFragments = slices.Delete(compositeFragments, bestFragment, bestFragment+1)
		}
	}

	return pairwiseMerging(queryAccessSets, partialSolution, partitioningParameters)
}

func generateCompositeFragments(queryAccessSets []QueryAccessSet, atomicFragments, selectedFragments [][]int, minimumQueryExtent int) [][]int {
	var compositeFragments [][]int
	for _, selectedFragment := range selectedFragments {
		for _, extension := range slices.Concat(atomicFragments, selectedFragments) {
			compositeFragment := workload.AttributeUnion(selectedFragment, extension)
			if len(compositeFragment) == len(selectedFragment) ||
				slices.ContainsFunc(compositeFragments, func(fragment []int) bool { return slices.Equal(fragment, compositeFragment) }) ||
				len(queryExtent(queryAccessSets, atomicFragments, compositeFragment)) < minimumQueryExtent {
				continue
			}

			compositeFragments = append(compositeFragments, compositeFragment)
		}
	}

	return compositeFragments
}

func queryExtent(queryAccessSets []QueryAccessSet, atomicFragments [][]int, fragment []int) []int {
	var extentQueries []int
	for queryIndex, queryAccessSet := range queryAccessSets {
		referencesEveryComponent := true
		for _, atomicFragment := range atomicFragments {
			if workload.IsAttributeSubset(atomicFragment, fragment) && len(workload.AttributeIntersection(atomicFragment, queryAccessSet.QueryAttributes)) == 0 {
				referencesEveryComponent = false
				break
			}
		}
		if referencesEveryComponent {
			extentQueries = append(extentQueries, queryIndex)
		}
	}

	return extentQueries
}

func addFragment(schema [][]int, fragment []int) [][]int {
	var extendedSchema [][]int
	for _, schemaFragment := range schema {
		if !workload.IsAttributeSubset(schemaFragment, fragment) {
			extendedSchema = append(extendedSchema, schemaFragment)
		}
	}

	return append(extendedSchema, fragment)
}

func pairwiseMerging(queryAccessSets []QueryAccessSet, schema [][]int, partitioningParameters PartitioningParameters) [][]int {
	schemaCost := WorkloadCost(queryAccessSets, schema, partitioningParameters)
	for {
		bestSchema, bestCost := [][]int(nil), schemaCost
		for firstFragment := range schema {
			for secondFragment := firstFragment + 1; secondFragment < len(schema); secondFragment++ {
				mergedSchema := addFragment(schema, workload.AttributeUnion(schema[firstFragment], schema[secondFragment]))
				if mergedCost := WorkloadCost(queryAccessSets, mergedSchema, partitioningParameters); mergedCost < bestCost {
					bestSchema, bestCost = mergedSchema, mergedCost
				}
			}
		}
		if bestSchema == nil {
			return schema
		}

		schema, schemaCost = bestSchema, bestCost
	}
}

func WorkloadCost(queryAccessSets []QueryAccessSet, schema [][]int, partitioningParameters PartitioningParameters) float64 {
	var workloadCost float64
	for _, queryAccessSet := range queryAccessSets {
		workloadCost += queryAccessSet.QueryFrequency * queryCost(queryAccessSet, schema, partitioningParameters)
	}

	return workloadCost
}

func queryCost(queryAccessSet QueryAccessSet, schema [][]int, partitioningParameters PartitioningParameters) float64 {
	var relevantFragments [][]int
	for _, fragment := range schema {
		if len(workload.AttributeIntersection(fragment, queryAccessSet.QueryAttributes)) > 0 {
			relevantFragments = append(relevantFragments, fragment)
		}
	}

	cheapestPlan := math.Inf(1)
	for planMask := 1; planMask < 1<<len(relevantFragments); planMask++ {
		var coveredAttributes []int
		var scanCost float64
		var planFragments int
		for fragmentIndex, fragment := range relevantFragments {
			if planMask&(1<<fragmentIndex) == 0 {
				continue
			}
			coveredAttributes = workload.AttributeUnion(coveredAttributes, fragment)
			scanCost += partitioningParameters.ScanScalingFactor * float64(len(fragment))
			planFragments++
		}

		if workload.IsAttributeSubset(queryAccessSet.QueryAttributes, coveredAttributes) {
			joinCost := float64(planFragments-1) * partitioningParameters.FragmentJoinCost
			cheapestPlan = min(cheapestPlan, scanCost+joinCost)
		}
	}

	return cheapestPlan
}

func replicatedBytes(schema [][]int, attributeBytes []float64) float64 {
	var storedBytes float64
	var storedAttributes []int
	for _, fragment := range schema {
		for _, attribute := range fragment {
			storedBytes += attributeBytes[attribute]
		}
		storedAttributes = workload.AttributeUnion(storedAttributes, fragment)
	}

	var distinctBytes float64
	for _, attribute := range storedAttributes {
		distinctBytes += attributeBytes[attribute]
	}

	return storedBytes - distinctBytes
}

func total(values []float64) float64 {
	var sum float64
	for _, value := range values {
		sum += value
	}

	return sum
}

func cloneFragments(fragments [][]int) [][]int {
	clonedFragments := make([][]int, len(fragments))
	for fragmentIndex, fragment := range fragments {
		clonedFragments[fragmentIndex] = slices.Clone(fragment)
	}

	return clonedFragments
}
