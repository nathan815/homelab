package app

import (
	"fmt"
	"strings"

	"github.com/nathan815/stackctl/internal/dockerutil"
	"github.com/urfave/cli/v2"
)

/*
Commands I want:

stackctl deploy media-system
Copies files for this stack to the host, then brings it up (or restarts it).
Deploy = Push + Up

stackctl push media-system
Copies files for this stack to the host

stackctl restart media-system
Runs `docker compose down && docker compose up` for this stack

stackctl down media-system
Runs `docker compose down` for this stack

stackctl up media-system
Runs `docker compose up` for this stack

stackctl list
Lists all stacks

stackctl copy media-system src-host dest-host
Copies files for this stack from one host to another

stackctl copy-volumes media-system src-host dest-host
  Copies all docker volumes in this stack from one host to another
*/

var PushCmd = &cli.Command{
	Name:      "push",
	Usage:     "copies files for a stack to host(s)",
	Args:      true,
	ArgsUsage: "<stack>",
	Action: func(ctx *cli.Context) error {
		stackName := ctx.Args().First()
		if stackName == "" {
			return fmt.Errorf("stack name is required")
		}

		fmt.Println("pushing stack ", stackName)
		client, err := dockerutil.Connect()
		if err != nil {
			return err
		}
		containers, err := dockerutil.GetContainers(client)
		if err != nil {
			return err
		}
		fmtStr := "%-25s %-50s %-20s %-25s %-20s\n"
		fmt.Printf(fmtStr, "NAME", "IMAGE", "STATE", "STATUS", "ID")
		for _, container := range containers {
			fmt.Printf(fmtStr, strings.Trim(container.Names[0], "/"), container.Image, container.State, container.Status, container.ID)
		}
		return nil
	},
}

var DeployCmd = &cli.Command{
	Name:      "deploy",
	Usage:     "pushes a stack and then brings it up or restarts it",
	Args:      true,
	ArgsUsage: "<stack>",
	Action: func(ctx *cli.Context) error {
		fmt.Println("deploying stack")
		return nil
	},
}

var RestartCmd = &cli.Command{
	Name:      "restart",
	Usage:     "restarts a stack on host",
	Args:      true,
	ArgsUsage: "<stack>",
	Action: func(ctx *cli.Context) error {
		fmt.Println("restarting stack")
		return nil
	},
}

var DownCmd = &cli.Command{
	Name:      "down",
	Usage:     "brings down a stack on host",
	Args:      true,
	ArgsUsage: "<stack>",
	Action: func(ctx *cli.Context) error {
		fmt.Println("bringing down stack")
		return nil
	},
}

var UpCmd = &cli.Command{
	Name:      "up",
	Usage:     "brings up a stack on host",
	Args:      true,
	ArgsUsage: "<stack>",
	Action: func(ctx *cli.Context) error {
		fmt.Println("bringing up stack")
		return nil
	},
}

var AllCommands = []*cli.Command{
	PushCmd,
	DeployCmd,
	RestartCmd,
	DownCmd,
	UpCmd,
}
