package main

import (
	"fmt"

	"github.com/google/uuid"
)

func NewID() string { return uuid.NewString() }

func main() { fmt.Println(NewID()) }
