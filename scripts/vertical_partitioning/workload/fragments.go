package workload

import (
	"slices"
	"strings"
)

func (entity Entity) NonKeyAttributeBytes() []float64 {
	var attributeBytes []float64
	for _, attribute := range entity.NonKeyAttributes() {
		attributeBytes = append(attributeBytes, attribute.AttributeBytes)
	}

	return attributeBytes
}

func AttributeUnion(firstAttributes, secondAttributes []int) []int {
	unitedAttributes := slices.Clone(firstAttributes)
	for _, attribute := range secondAttributes {
		if !slices.Contains(unitedAttributes, attribute) {
			unitedAttributes = append(unitedAttributes, attribute)
		}
	}
	slices.Sort(unitedAttributes)

	return unitedAttributes
}

func AttributeIntersection(firstAttributes, secondAttributes []int) []int {
	var sharedAttributes []int
	for _, attribute := range firstAttributes {
		if slices.Contains(secondAttributes, attribute) {
			sharedAttributes = append(sharedAttributes, attribute)
		}
	}

	return sharedAttributes
}

func AttributeDifference(firstAttributes, secondAttributes []int) []int {
	var remainingAttributes []int
	for _, attribute := range firstAttributes {
		if !slices.Contains(secondAttributes, attribute) {
			remainingAttributes = append(remainingAttributes, attribute)
		}
	}

	return remainingAttributes
}

func IsAttributeSubset(subsetAttributes, supersetAttributes []int) bool {
	for _, attribute := range subsetAttributes {
		if !slices.Contains(supersetAttributes, attribute) {
			return false
		}
	}

	return true
}

func FragmentNames(fragments [][]int, attributes []Attribute) string {
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
