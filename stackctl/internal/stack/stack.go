package stack

type Stack struct {
	Name        string
	EnvDefaults map[string]string
	FilePaths   []string
}

func New(name string) *Stack {
	return &Stack{
		Name:        name,
		EnvDefaults: make(map[string]string),
		FilePaths:   make([]string, 0),
	}
}

func FromDirectory(dir string) *Stack {
	return nil
}

func readEnvDefaults() map[string]string {
	return nil
}

func CopyToHost() {

}
