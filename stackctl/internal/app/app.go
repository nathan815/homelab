package app

import (
	"log"

	"github.com/urfave/cli/v2"
)

var app = &cli.App{
	Name:     "stackctl",
	Usage:    "manage your docker stacks with ease",
	Commands: AllCommands,
}

func Run(args []string) {
	err := app.Run(args)
	if err != nil {
		log.Fatal(err)
	}
}
