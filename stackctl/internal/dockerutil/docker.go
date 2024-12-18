package dockerutil

import (
	"context"
	"fmt"
	"net/http"
	"os"

	"github.com/docker/cli/cli/connhelper"
	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/client"
)

func Connect() (*client.Client, error) {

	helper, err := connhelper.GetConnectionHelper("ssh://nathan@pi01.lan:22")

	if err != nil {
		return nil, err
	}

	httpClient := &http.Client{
		// No tls
		// No proxy
		Transport: &http.Transport{
			DialContext: helper.Dialer,
		},
	}

	var clientOpts []client.Opt

	clientOpts = append(clientOpts,
		client.WithHTTPClient(httpClient),
		client.WithHost(helper.Host),
		client.WithDialContext(helper.Dialer),
	)

	version := os.Getenv("DOCKER_API_VERSION")

	if version != "" {
		clientOpts = append(clientOpts, client.WithVersion(version))
	} else {
		clientOpts = append(clientOpts, client.WithAPIVersionNegotiation())
	}

	client, err := client.NewClientWithOpts(clientOpts...)

	if err != nil {
		return nil, fmt.Errorf("error creating docker client: %w", err)
	}

	return client, nil
}

func GetImages(client *client.Client) ([]image.Summary, error) {
	images, err := client.ImageList(context.Background(), image.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error listing images: %w", err)
	}
	return images, nil
}

func GetContainers(client *client.Client) ([]types.Container, error) {
	containers, err := client.ContainerList(context.Background(), container.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("error listing containers: %w", err)
	}
	return containers, nil
}
