// Navathe, Ceri, Wiederhold and Dou, "Vertical Partitioning Algorithms for Database Design" (TODS 1984)
package navathe

import (
	"math"
	"slices"

	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

type TransactionType string

const (
	RetrievalTransaction TransactionType = "retrieval"
	UpdateTransaction    TransactionType = "update"
)

type AttributeUsage struct {
	TransactionName       string
	TransactionType       TransactionType
	TransactionAccesses   float64
	TransactionAttributes []int
}

type PartitioningOptions struct {
	WithOverlap     bool
	WithShift       bool
	WithCluster     bool
	WithCostFactors bool
	CostFactors     CostFactors
}

type CostFactors struct {
	IrrelevantByteCost float64
	FragmentAccessCost float64
	ReplicatedByteCost float64
}

type binarySplit struct {
	upperFragment      []int
	lowerFragment      []int
	splitIsImprovement bool
	splitObjective     float64
}

func AttributeUsages(entity workload.Entity, attributes []workload.Attribute, workloadName string) []AttributeUsage {
	var attributeUsages []AttributeUsage
	for _, transaction := range workload.Transactions {
		for _, access := range transaction.TransactionAccesses {
			usedAttributes, transactionType := attributeAccess(access, attributes)
			if access.EntityName != entity.EntityName || len(usedAttributes) == 0 {
				continue
			}

			attributeUsages = append(attributeUsages, AttributeUsage{
				TransactionName:       transaction.TransactionName,
				TransactionType:       transactionType,
				TransactionAccesses:   access.AccessedRecords * transaction.TransactionWeights[workloadName],
				TransactionAttributes: usedAttributes,
			})
		}
	}

	return attributeUsages
}

func attributeAccess(access workload.EntityAccess, attributes []workload.Attribute) ([]int, TransactionType) {
	var usedAttributes []int
	transactionType := RetrievalTransaction
	for attributeIndex, attribute := range attributes {
		if access.UsesAttribute(attribute.AttributeName) {
			usedAttributes = append(usedAttributes, attributeIndex)
		}
		if slices.Contains(access.WriteAttributes, attribute.AttributeName) {
			transactionType = UpdateTransaction
		}
	}

	return usedAttributes, transactionType
}

func AffinityMatrix(attributeUsages []AttributeUsage, attributeCount int) [][]float64 {
	affinityMatrix := make([][]float64, attributeCount)
	for row := range affinityMatrix {
		affinityMatrix[row] = make([]float64, attributeCount)
	}

	for _, attributeUsage := range attributeUsages {
		for _, firstAttribute := range attributeUsage.TransactionAttributes {
			for _, secondAttribute := range attributeUsage.TransactionAttributes {
				affinityMatrix[firstAttribute][secondAttribute] += attributeUsage.TransactionAccesses
			}
		}
	}

	return affinityMatrix
}

func ClusteredOrder(attributeUsages []AttributeUsage, fragment []int, attributeCount int) []int {
	affinityMatrix := AffinityMatrix(relevantUsages(attributeUsages, fragment), attributeCount)
	fragmentMatrix := PermutedMatrix(affinityMatrix, fragment)

	fragmentOrder := BondEnergyOrder(fragmentMatrix)
	clusteredOrder := make([]int, len(fragmentOrder))
	for position, fragmentPosition := range fragmentOrder {
		clusteredOrder[position] = fragment[fragmentPosition]
	}

	return clusteredOrder
}

func Fragments(attributeUsages []AttributeUsage, attributeBytes []float64, options PartitioningOptions) [][]int {
	allAttributes := make([]int, len(attributeBytes))
	for attribute := range allAttributes {
		allAttributes[attribute] = attribute
	}

	clusteredOrder := ClusteredOrder(attributeUsages, allAttributes, len(attributeBytes))

	return splitRepeatedly(attributeUsages, attributeBytes, clusteredOrder, options)
}

func splitRepeatedly(attributeUsages []AttributeUsage, attributeBytes []float64, fragment []int, options PartitioningOptions) [][]int {
	fragmentUsages := relevantUsages(attributeUsages, fragment)
	if options.WithCluster {
		fragment = ClusteredOrder(fragmentUsages, fragment, len(attributeBytes))
	}

	bestSplit := bestBinarySplit(fragmentUsages, attributeBytes, fragment, options)
	if !bestSplit.splitIsImprovement {
		return [][]int{fragment}
	}

	return append(
		splitRepeatedly(fragmentUsages, attributeBytes, bestSplit.upperFragment, options),
		splitRepeatedly(fragmentUsages, attributeBytes, bestSplit.lowerFragment, options)...,
	)
}

func bestBinarySplit(fragmentUsages []AttributeUsage, attributeBytes []float64, fragment []int, options PartitioningOptions) binarySplit {
	bestSplit := binarySplit{splitObjective: math.Inf(-1)}
	unsplitObjective := 0.0
	if options.WithCostFactors {
		unsplitObjective = -partitionCost(fragmentUsages, attributeBytes, fragment, fragment, options.CostFactors)
	}

	shiftCount := 1
	if options.WithShift {
		shiftCount = len(fragment)
	}

	for shift := range shiftCount {
		shiftedFragment := append(slices.Clone(fragment[shift:]), fragment[:shift]...)
		for upperEnd := 1; upperEnd < len(shiftedFragment); upperEnd++ {
			lowerStart := upperEnd
			if options.WithOverlap {
				lowerStart = 1
			}

			for ; lowerStart <= upperEnd; lowerStart++ {
				upperFragment, lowerFragment := shiftedFragment[:upperEnd], shiftedFragment[lowerStart:]
				splitObjective := partitionObjective(fragmentUsages, attributeBytes, upperFragment, lowerFragment, options)
				if splitObjective > bestSplit.splitObjective {
					bestSplit = binarySplit{
						upperFragment:      upperFragment,
						lowerFragment:      lowerFragment,
						splitIsImprovement: splitObjective > unsplitObjective,
						splitObjective:     splitObjective,
					}
				}
			}
		}
	}

	return bestSplit
}

func partitionObjective(fragmentUsages []AttributeUsage, attributeBytes []float64, upperFragment, lowerFragment []int, options PartitioningOptions) float64 {
	if options.WithCostFactors {
		return -partitionCost(fragmentUsages, attributeBytes, upperFragment, lowerFragment, options.CostFactors)
	}

	upperAccesses, lowerAccesses, bothAccesses := partitionAccesses(fragmentUsages, upperFragment, lowerFragment)

	return upperAccesses*lowerAccesses - bothAccesses*bothAccesses
}

func partitionAccesses(fragmentUsages []AttributeUsage, upperFragment, lowerFragment []int) (upperAccesses, lowerAccesses, bothAccesses float64) {
	for _, attributeUsage := range fragmentUsages {
		matchesUpper, matchesLower := matchedFragments(attributeUsage, upperFragment, lowerFragment)
		switch {
		case matchesUpper && matchesLower:
			upperAccesses += attributeUsage.TransactionAccesses
			lowerAccesses += attributeUsage.TransactionAccesses
		case matchesUpper:
			upperAccesses += attributeUsage.TransactionAccesses
		case matchesLower:
			lowerAccesses += attributeUsage.TransactionAccesses
		default:
			bothAccesses += attributeUsage.TransactionAccesses
		}
	}

	return upperAccesses, lowerAccesses, bothAccesses
}

func partitionCost(fragmentUsages []AttributeUsage, attributeBytes []float64, upperFragment, lowerFragment []int, costFactors CostFactors) float64 {
	var sharedAttributes []int
	if !slices.Equal(upperFragment, lowerFragment) {
		sharedAttributes = intersection(upperFragment, lowerFragment)
	}

	var irrelevantBytes, fragmentAccesses float64
	for _, attributeUsage := range fragmentUsages {
		for _, accessedFragment := range accessedFragments(attributeUsage, upperFragment, lowerFragment) {
			for _, attribute := range accessedFragment {
				if !slices.Contains(attributeUsage.TransactionAttributes, attribute) {
					irrelevantBytes += attributeUsage.TransactionAccesses * attributeBytes[attribute]
				}
			}
			fragmentAccesses += attributeUsage.TransactionAccesses
		}
	}

	var replicatedBytes float64
	for _, attribute := range sharedAttributes {
		replicatedBytes += attributeBytes[attribute]
	}

	return costFactors.IrrelevantByteCost*irrelevantBytes +
		costFactors.FragmentAccessCost*fragmentAccesses +
		costFactors.ReplicatedByteCost*replicatedBytes
}

func accessedFragments(attributeUsage AttributeUsage, upperFragment, lowerFragment []int) [][]int {
	if slices.Equal(upperFragment, lowerFragment) {
		return [][]int{upperFragment}
	}

	matchesUpper, matchesLower := matchedFragments(attributeUsage, upperFragment, lowerFragment)
	switch {
	case matchesUpper:
		return [][]int{upperFragment}
	case matchesLower:
		return [][]int{lowerFragment}
	default:
		return [][]int{upperFragment, lowerFragment}
	}
}

func matchedFragments(attributeUsage AttributeUsage, upperFragment, lowerFragment []int) (matchesUpper, matchesLower bool) {
	sharedAttributes := intersection(upperFragment, lowerFragment)
	if attributeUsage.TransactionType == UpdateTransaction {
		upperFragment, lowerFragment = difference(upperFragment, sharedAttributes), difference(lowerFragment, sharedAttributes)
	}

	return isSubset(attributeUsage.TransactionAttributes, upperFragment), isSubset(attributeUsage.TransactionAttributes, lowerFragment)
}

func relevantUsages(attributeUsages []AttributeUsage, fragment []int) []AttributeUsage {
	var fragmentUsages []AttributeUsage
	for _, attributeUsage := range attributeUsages {
		fragmentAttributes := intersection(attributeUsage.TransactionAttributes, fragment)
		if len(fragmentAttributes) == 0 {
			continue
		}

		attributeUsage.TransactionAttributes = fragmentAttributes
		fragmentUsages = append(fragmentUsages, attributeUsage)
	}

	return fragmentUsages
}

func intersection(firstAttributes, secondAttributes []int) []int {
	var sharedAttributes []int
	for _, attribute := range firstAttributes {
		if slices.Contains(secondAttributes, attribute) {
			sharedAttributes = append(sharedAttributes, attribute)
		}
	}

	return sharedAttributes
}

func difference(firstAttributes, secondAttributes []int) []int {
	var remainingAttributes []int
	for _, attribute := range firstAttributes {
		if !slices.Contains(secondAttributes, attribute) {
			remainingAttributes = append(remainingAttributes, attribute)
		}
	}

	return remainingAttributes
}

func isSubset(subsetAttributes, supersetAttributes []int) bool {
	for _, attribute := range subsetAttributes {
		if !slices.Contains(supersetAttributes, attribute) {
			return false
		}
	}

	return true
}
