package main

import (
	"flag"
	"fmt"
	"os"
	"slices"
	"strings"

	hillclimb "github.com/cs4224-grp08/project/scripts/vertical_partitioning/2_hillclimb"
	"github.com/cs4224-grp08/project/scripts/vertical_partitioning/workload"
)

func main() {
	workloadName := flag.String("workload", "A", "Workload A or B")
	cacheLineBytes := flag.Float64("cache-line-bytes", 64, "Size of the unit the cost model counts misses of")

	flag.Parse()

	if !slices.Contains(workload.WorkloadNames, *workloadName) {
		fmt.Fprintf(os.Stderr, "Unknown Workload %q\n", *workloadName)
		os.Exit(2)
	}

	for _, entity := range workload.Entities {
		attributes := entity.NonKeyAttributes()
		attributeBytes := make([]float64, len(attributes))
		for attributeIndex, attribute := range attributes {
			attributeBytes[attributeIndex] = attribute.AttributeBytes
		}

		queryAccesses := hillclimb.QueryAccesses(entity, attributes, *workloadName)
		hillClimbPartition := hillclimb.HillClimb(queryAccesses, attributeBytes, *cacheLineBytes)
		naivePartition := hillclimb.Naive(queryAccesses, attributeBytes, *cacheLineBytes)

		fmt.Printf("\n## %s (workload %s, cache line = %g bytes)\n", entity.EntityName, *workloadName, *cacheLineBytes)
		fmt.Println("\nQuery access rates")
		printQueryAccesses(queryAccesses, attributes)
		fmt.Printf("\nHill-Climb  %12.6g  %s\n", hillclimb.PartitionCost(queryAccesses, attributeBytes, hillClimbPartition, *cacheLineBytes), groupNames(hillClimbPartition, attributes))
		fmt.Printf("Naive       %12.6g  %s\n", hillclimb.PartitionCost(queryAccesses, attributeBytes, naivePartition, *cacheLineBytes), groupNames(naivePartition, attributes))
	}
}

func printQueryAccesses(queryAccesses []hillclimb.QueryAccess, attributes []workload.Attribute) {
	fmt.Printf("%-11s %9s", "transaction", "frequency")
	for _, attribute := range attributes {
		fmt.Printf(" %14s", attribute.AttributeName)
	}
	fmt.Println()

	for _, queryAccess := range queryAccesses {
		fmt.Printf("%-11s %9g", queryAccess.QueryName, queryAccess.QueryFrequency)
		for _, accessRate := range queryAccess.QueryAccessRates {
			fmt.Printf(" %14.2g", accessRate)
		}
		fmt.Println()
	}
}

func groupNames(partition [][]int, attributes []workload.Attribute) string {
	groupNames := make([]string, len(partition))
	for groupIndex, group := range partition {
		attributeNames := make([]string, len(group))
		for groupPosition, attribute := range group {
			attributeNames[groupPosition] = attributes[attribute].AttributeName
		}
		groupNames[groupIndex] = "{" + strings.Join(attributeNames, ", ") + "}"
	}

	return strings.Join(groupNames, " ")
}
