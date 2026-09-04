package database

import (
	"errors"
	"fmt"
	"strings"
)

var ErrInvalidDisplayName = errors.New("invalid actor display name")

// NormalizeDisplayName trims a display name and enforces the same bounds used
// by the group_actors.display_name database constraint.
func NormalizeDisplayName(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("%w: name must not be empty", ErrInvalidDisplayName)
	}
	if len([]rune(value)) > 255 {
		return "", fmt.Errorf("%w: name must be at most 255 characters", ErrInvalidDisplayName)
	}
	return value, nil
}
