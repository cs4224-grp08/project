package main

import (
	"flag"
	"fmt"
	"os"
	"slices"
	"strings"

	autopart "github.com/cs4224-grp08/project/scripts/vertical_partitioning/3_autopart"
	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

func main() {
	workloadName := flag.String("workload", "A", "Workload A or B")
	scanScalingFactor := flag.Float64("scan-scaling", 1, "SR, the cost of scanning one attribute of a fragment")
	fragmentJoinCost := flag.Float64("join-cost", 18.76, "J, the cost of joining one more fragment (from 3_autopart/join_cost_calibration.sql)")
	replicationBudget := flag.Float64("replication-budget", 0, "Replicated bytes allowed, as a fraction of the relation's bytes")
	minimumQueryExtent := flag.Int("minimum-query-extent", 1, "X, the fewest queries a composite fragment must serve")

	flag.Parse()

	if !slices.Contains(workload.WorkloadNames, *workloadName) {
		fmt.Fprintf(os.Stderr, "Unknown Workload %q\n", *workloadName)
		os.Exit(2)
	}

	partitioningParameters := autopart.PartitioningParameters{
		ScanScalingFactor:  *scanScalingFactor,
		FragmentJoinCost:   *fragmentJoinCost,
		ReplicationBudget:  *replicationBudget,
		MinimumQueryExtent: *minimumQueryExtent,
	}

	for _, entity := range workload.Entities {
		attributes := entity.NonKeyAttributes()
		attributeBytes := make([]float64, len(attributes))
		for attributeIndex, attribute := range attributes {
			attributeBytes[attributeIndex] = attribute.AttributeBytes
		}

		queryAccessSets := autopart.QueryAccessSets(entity, attributes, *workloadName)
		atomicFragments := autopart.AtomicFragments(queryAccessSets, len(attributes))
		fragments := autopart.Partitioning(queryAccessSets, attributeBytes, partitioningParameters)

		fmt.Printf("\n## %s (workload %s, SR = %g, J = %g, replication budget = %g)\n", entity.EntityName, *workloadName,
			*scanScalingFactor, *fragmentJoinCost, *replicationBudget)
		fmt.Println("\nQuery access sets")
		printQueryAccessSets(queryAccessSets, attributes)
		fmt.Printf("\nAtomic fragments  %10.6g  %s\n", autopart.WorkloadCost(queryAccessSets, atomicFragments, partitioningParameters), fragmentNames(atomicFragments, attributes))
		fmt.Printf("Fragments         %10.6g  %s\n", autopart.WorkloadCost(queryAccessSets, fragments, partitioningParameters), fragmentNames(fragments, attributes))
	}
}

func printQueryAccessSets(queryAccessSets []autopart.QueryAccessSet, attributes []workload.Attribute) {
	fmt.Printf("%-11s %9s", "transaction", "frequency")
	for _, attribute := range attributes {
		fmt.Printf(" %14s", attribute.AttributeName)
	}
	fmt.Println()

	for _, queryAccessSet := range queryAccessSets {
		fmt.Printf("%-11s %9g", queryAccessSet.QueryName, queryAccessSet.QueryFrequency)
		for attribute := range attributes {
			attributeIsUsed := 0
			if slices.Contains(queryAccessSet.QueryAttributes, attribute) {
				attributeIsUsed = 1
			}
			fmt.Printf(" %14d", attributeIsUsed)
		}
		fmt.Println()
	}
}

func fragmentNames(fragments [][]int, attributes []workload.Attribute) string {
	fragmentNames := make([]string, len(fragments))
	for fragmentIndex, fragment := range fragments {
		attributeNames := make([]string, len(fragment))
		for fragmentPosition, attribute := range fragment {
			attributeNames[fragmentPosition] = attributes[attribute].AttributeName
		}
		fragmentNames[fragmentIndex] = "{" + strings.Join(attributeNames, ", ") + "}"
	}

	return strings.Join(fragmentNames, " ")
}
