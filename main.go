package main

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/fatih/color"
	"github.com/goccy/go-json"
	"github.com/mitchellh/cli"
	"github.com/mitchellh/go-homedir"
	"golang.org/x/exp/slices"
)

var configFilePath string

func init() {
	home, err := homedir.Dir()
	if err != nil {
		log.Fatal("cannot get home directory")
	}
	configFilePath = filepath.Join(home, ".ug", "cmd.json")
}

func loadConfig() (map[string]string, error) {
	configContent, err := os.ReadFile(configFilePath)
	if err != nil {
		if !os.IsNotExist(err) {
			return nil, err
		}
		if file, err := os.Create(configFilePath); err != nil {
			return nil, err
		} else {
			if err := file.Close(); err != nil {
				return nil, err
			}
		}
	}
	if bytes.Equal(configContent, []byte("")) {
		configContent = []byte("{}")
	}
	var config map[string]string
	if err := json.Unmarshal(configContent, &config); err != nil {
		return nil, err
	}
	return config, nil
}

func writeConfig(config map[string]string) error {
	newConfigContent, err := json.Marshal(&config)
	if err != nil {
		return err
	}

	if err := os.WriteFile(configFilePath, newConfigContent, 0755); err != nil {
		return err
	}

	return nil
}

type setCommand struct{}

func (c *setCommand) Run(args []string) int {
	var (
		name           string
		upgradeCommand string
	)
	for i := 0; i < len(args); {
		var arg = args[i]
		if arg == "-name" {
			name = args[i+1]
			i++
		}
		if arg == "-command" {
			upgradeCommand = args[i+1]
			i++
		}
		i++
	}

	if name == "" || upgradeCommand == "" {
		log.Print("-name or -command is not set")
		return 0
	}

	if err := os.MkdirAll(filepath.Dir(configFilePath), 0755); err != nil {
		log.Print("cannot create config directory: ", err)
		return 1
	}

	config, err := loadConfig()
	if err != nil {
		log.Print("cannot load config: ", err)
		return 1
	}

	config[name] = upgradeCommand
	if err := writeConfig(config); err != nil {
		log.Print("cannot write config to file: ", err)
		return 1
	}

	return 0
}

func (c *setCommand) Help() string {
	return "Set upgrade command with name"
}

func (c *setCommand) Synopsis() string {
	return ""
}

type unsetCommand struct{}

func (c *unsetCommand) Run(args []string) int {
	var name string

	for i := 0; i < len(args); {
		var arg = args[i]
		if arg == "-name" {
			name = args[i+1]
			i++
		}
	}

	if name == "" {
		log.Print("-name is not set")
		os.Exit(0)
	}

	config, err := loadConfig()
	if err != nil {
		log.Print("cannot load config: ", err)
		return 1
	}

	delete(config, name)
	if err := writeConfig(config); err != nil {
		log.Print("cannot write config to file: ", err)
		return 1
	}

	return 0
}

func (c *unsetCommand) Help() string {
	return "Delete upgrade command with name"
}

func (c *unsetCommand) Synopsis() string {
	return ""
}

type listCommand struct{}

func (c *listCommand) Run(args []string) int {
	config, err := loadConfig()
	if err != nil {
		log.Print("cannot load config: ", err)
		return 1
	}

	var maxLength int
	for k := range config {
		l := len(k)
		if maxLength == 0 || l > maxLength {
			maxLength = l
		}
	}

	buf := bytes.Buffer{}
	for k, v := range config {
		key := k + strings.Repeat(" ", maxLength-len(k))
		buf.WriteString(fmt.Sprintf("%s = %s\n", key, color.GreenString(v)))
	}

	fmt.Println(buf.String())
	return 0
}

func (c *listCommand) Help() string {
	return "List upgrade command with name"
}

func (c *listCommand) Synopsis() string {
	return ""
}

func createCommand(cmd string) *exec.Cmd {
	return exec.Command("bash", "-c", cmd)
}

func runUpgrade(name string) {
	config, err := loadConfig()
	if err != nil {
		log.Fatal("cannot load config: ", err)
	}

	upgradeCommand, ok := config[name]
	if !ok {
		log.Fatalf("%s is not set in config, %s", name, err)
	}

	cmd := createCommand(upgradeCommand)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatalf("cannot run upgrade command %s, %s", upgradeCommand, err)
	}
}

func isValidCommand(cmd string) bool {
	return !slices.Contains([]string{"set", "unset", "list"}, cmd) && cmd != ""
}

func main() {
	c := cli.NewCLI("ugg", "1.0.0")

	c.Args = os.Args[1:]
	c.Commands = map[string]cli.CommandFactory{
		"set": func() (cli.Command, error) {
			return &setCommand{}, nil
		},
		"unset": func() (cli.Command, error) {
			return &unsetCommand{}, nil
		},
		"list": func() (cli.Command, error) {
			return &listCommand{}, nil
		},
	}

	if cmd := c.Subcommand(); isValidCommand(cmd) {
		runUpgrade(cmd)
		os.Exit(0)
	}

	exitStatus, err := c.Run()
	if err != nil {
		log.Println(err)
	}

	os.Exit(exitStatus)
}
