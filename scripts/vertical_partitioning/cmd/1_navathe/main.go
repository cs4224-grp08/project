package main

import (
	"flag"
	"fmt"
	"os"
	"slices"
	"strings"

	navathe "github.com/cs4224-grp08/project/scripts/vertical_partitioning/1_navathe"
	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

func main() {
	workloadName := flag.String("workload", "A", "Workload A or B")
	withOverlap := flag.Bool("overlap", false, "Allow overlapping fragments (SPLIT-OVERLAP)")
	withShift := flag.Bool("shift", false, "Try every rotation of the clustered order (SHIFT)")
	withCluster := flag.Bool("cluster", false, "Recluster each fragment before splitting it (CLUSTER)")
	withCostFactors := flag.Bool("cost-factors", false, "Split by cost factors (phase 2) instead of the empirical objective (phase 1)")
	irrelevantByteCost := flag.Float64("irrelevant-byte-cost", 1, "C1, cost of an irrelevant byte accessed")
	fragmentAccessCost := flag.Float64("fragment-access-cost", 1000, "C2, cost of accessing a fragment")
	replicatedByteCost := flag.Float64("replicated-byte-cost", 100, "C3, cost of storing a replicated byte")

	flag.Parse()

	if !slices.Contains(workload.WorkloadNames, *workloadName) {
		fmt.Fprintf(os.Stderr, "Unknown Workload %q\n", *workloadName)
		os.Exit(2)
	}

	partitioningOptions := navathe.PartitioningOptions{
		WithOverlap:     *withOverlap,
		WithShift:       *withShift,
		WithCluster:     *withCluster,
		WithCostFactors: *withCostFactors,
		CostFactors: navathe.CostFactors{
			IrrelevantByteCost: *irrelevantByteCost,
			FragmentAccessCost: *fragmentAccessCost,
			ReplicatedByteCost: *replicatedByteCost,
		},
	}

	for _, entity := range workload.Entities {
		attributes := entity.NonKeyAttributes()
		attributeBytes := entity.NonKeyAttributeBytes()
		allAttributes := make([]int, len(attributes))
		for attributeIndex := range allAttributes {
			allAttributes[attributeIndex] = attributeIndex
		}

		attributeUsages := navathe.AttributeUsages(entity, attributes, *workloadName)
		affinityMatrix := navathe.AffinityMatrix(attributeUsages, len(attributes))
		clusteredOrder := navathe.ClusteredOrder(attributeUsages, allAttributes, len(attributes))
		fragments := navathe.Fragments(attributeUsages, attributeBytes, partitioningOptions)

		fmt.Printf("\n## %s (workload %s, %s)\n", entity.EntityName, *workloadName, describeOptions(partitioningOptions))
		fmt.Println("\nAttribute usages")
		printAttributeUsages(attributeUsages, attributes)
		fmt.Println("\nAffinity matrix")
		printMatrix(affinityMatrix, attributes, allAttributes)
		fmt.Println("\nAffinity matrix in clustered order")
		printMatrix(navathe.PermutedMatrix(affinityMatrix, clusteredOrder), attributes, clusteredOrder)
		fmt.Printf("\nFragments  %s\n", workload.FragmentNames(fragments, attributes))
	}
}

func describeOptions(partitioningOptions navathe.PartitioningOptions) string {
	optionNames := []string{"split"}
	if partitioningOptions.WithOverlap {
		optionNames = append(optionNames, "overlap")
	}
	if partitioningOptions.WithShift {
		optionNames = append(optionNames, "shift")
	}
	if partitioningOptions.WithCluster {
		optionNames = append(optionNames, "cluster")
	}
	if partitioningOptions.WithCostFactors {
		optionNames = append(optionNames, fmt.Sprintf("cost factors %g/%g/%g",
			partitioningOptions.CostFactors.IrrelevantByteCost,
			partitioningOptions.CostFactors.FragmentAccessCost,
			partitioningOptions.CostFactors.ReplicatedByteCost))
	}

	return strings.Join(optionNames, ", ")
}

func printAttributeUsages(attributeUsages []navathe.AttributeUsage, attributes []workload.Attribute) {
	fmt.Printf("%-11s %-9s %12s", "transaction", "type", "accesses")
	for _, attribute := range attributes {
		fmt.Printf(" %14s", attribute.AttributeName)
	}
	fmt.Println()

	for _, attributeUsage := range attributeUsages {
		fmt.Printf("%-11s %-9s %12.6g", attributeUsage.TransactionName, attributeUsage.TransactionType, attributeUsage.TransactionAccesses)
		for attribute := range attributes {
			attributeIsUsed := 0
			if slices.Contains(attributeUsage.TransactionAttributes, attribute) {
				attributeIsUsed = 1
			}
			fmt.Printf(" %14d", attributeIsUsed)
		}
		fmt.Println()
	}
}

func printMatrix(orderedMatrix [][]float64, attributes []workload.Attribute, attributeOrder []int) {
	fmt.Printf("%14s", "")
	for _, attribute := range attributeOrder {
		fmt.Printf(" %14s", attributes[attribute].AttributeName)
	}
	fmt.Println()

	for rowPosition, rowAttribute := range attributeOrder {
		fmt.Printf("%14s", attributes[rowAttribute].AttributeName)
		for columnPosition := range attributeOrder {
			fmt.Printf(" %14.6g", orderedMatrix[rowPosition][columnPosition])
		}
		fmt.Println()
	}
}
