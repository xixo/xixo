package updates

import (
	"encoding/json"
	"fmt"
	"reflect"
	"slices"
	"strings"
)

func object(held any) map[string]any {
	if found, ok := held.(map[string]any); ok {
		return found
	}

	return map[string]any{}
}

func texts(held any) []string {
	list, _ := held.([]any)
	out := make([]string, 0, len(list))

	for _, item := range list {
		if text, ok := item.(string); ok {
			out = append(out, text)
		}
	}

	return out
}

func same(held any, image any) bool {
	left, _ := json.Marshal(held)
	right, _ := json.Marshal(image)

	return string(left) == string(right)
}

func Recreated(container map[string]any, old Image, image string, imageID string) (map[string]any, error) {
	config := object(container["Config"])
	if config["Image"] != image {
		return nil, fmt.Errorf("the container runs %v, not %s, so the updater leaves it alone", config["Image"], image)
	}

	id, _ := container["Id"].(string)
	body := map[string]any{}

	for key, value := range config {
		body[key] = value
	}

	kept := []string{}
	for _, entry := range texts(config["Env"]) {
		if !slices.Contains(old.Config.Env, entry) {
			kept = append(kept, entry)
		}
	}
	body["Env"] = kept

	for key, held := range map[string]any{
		"Cmd": old.Config.Cmd, "Entrypoint": old.Config.Entrypoint, "WorkingDir": old.Config.WorkingDir,
		"User": old.Config.User, "StopSignal": old.Config.StopSignal, "Healthcheck": old.Config.Healthcheck,
	} {
		if value, present := config[key]; present && same(value, held) {
			delete(body, key)
		}
	}

	for key, image := range map[string]map[string]struct{}{"ExposedPorts": old.Config.Exposed, "Volumes": old.Config.Volumes} {
		listed := map[string]any{}
		for name, value := range object(config[key]) {
			if _, fromImage := image[name]; !fromImage {
				listed[name] = value
			}
		}
		body[key] = listed
	}

	labels := map[string]any{}
	for name, value := range object(config["Labels"]) {
		text, _ := value.(string)
		if fromImage, found := old.Config.Labels[name]; !found || fromImage != text {
			labels[name] = value
		}
	}
	if _, compose := labels["com.docker.compose.image"]; compose {
		labels["com.docker.compose.image"] = imageID
	}
	body["Labels"] = labels

	if hostname, _ := config["Hostname"].(string); len(id) >= 12 && hostname == id[:12] {
		delete(body, "Hostname")
	}

	host := object(container["HostConfig"])
	body["HostConfig"] = withAnonymous(host, container)

	endpoints := map[string]any{}
	for network, held := range object(object(container["NetworkSettings"])["Networks"]) {
		settings := object(held)
		aliases := []string{}
		for _, alias := range texts(settings["Aliases"]) {
			if len(id) < 12 || alias != id[:12] {
				aliases = append(aliases, alias)
			}
		}

		endpoint := map[string]any{"Aliases": aliases}
		for _, key := range []string{"IPAMConfig", "Links", "DriverOpts"} {
			if value := settings[key]; value != nil {
				endpoint[key] = value
			}
		}

		endpoints[network] = endpoint
	}
	body["NetworkingConfig"] = map[string]any{"EndpointsConfig": endpoints}

	return body, nil
}

func withAnonymous(host map[string]any, container map[string]any) map[string]any {
	copied := map[string]any{}
	for key, value := range host {
		copied[key] = value
	}

	named := map[string]bool{}
	for _, bind := range texts(host["Binds"]) {
		parts := strings.Split(bind, ":")
		if len(parts) >= 2 {
			named[parts[1]] = true
		}
	}

	mounts, _ := host["Mounts"].([]any)
	for _, mount := range mounts {
		if target, _ := object(mount)["Target"].(string); target != "" {
			named[target] = true
		}
	}

	added := append([]any{}, mounts...)
	held, _ := container["Mounts"].([]any)
	for _, mount := range held {
		described := object(mount)
		target, _ := described["Destination"].(string)
		name, _ := described["Name"].(string)

		if described["Type"] != "volume" || target == "" || name == "" || named[target] {
			continue
		}

		added = append(added, map[string]any{"Type": "volume", "Source": name, "Target": target})
	}

	if len(added) > 0 && !reflect.DeepEqual(added, mounts) {
		copied["Mounts"] = added
	}

	return copied
}
