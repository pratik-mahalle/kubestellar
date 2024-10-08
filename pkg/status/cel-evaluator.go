/*
Copyright 2024 The KubeStellar Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package status

import (
	"fmt"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/checker/decls"
	"github.com/google/cel-go/common/types/ref"

	"github.com/kubestellar/kubestellar/api/control/v1alpha1"
)

const (
	// returnedKey is the key used to store the status of the object
	// (WEC entity).
	returnedKey = "returned"
	// inventoryKey is the key used to store the inventory of the object.
	// (WEC entity).
	inventoryKey = "inventory"
	// propagationMetaKey is the key used to store the propagation metadata
	// of the object. (WEC entity).
	propagationMetaKey = "propagation"
	// sourceObjectKey is the key used to store the object.
	// (WDS entity).
	sourceObjectKey = "obj"
)

// celEvaluator is a struct that holds the CEL environment
// and provides a method to evaluate an expression with an unstructured object
// as the context.
type celEvaluator struct {
	env *cel.Env
}

// NewCELEvaluator initializes the CEL environment.
func newCELEvaluator() (*celEvaluator, error) {
	env, err := cel.NewEnv(
		cel.Declarations(
			decls.NewVar(sourceObjectKey, decls.NewMapType(decls.String, decls.Dyn)),
			decls.NewVar(returnedKey, decls.NewMapType(decls.String, decls.Dyn)),
			decls.NewVar(inventoryKey, decls.NewMapType(decls.String, decls.String)), // contains name:string only
			decls.NewVar(propagationMetaKey, decls.NewMapType(decls.String, decls.Dyn)),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create CEL environment: %v", err)
	}

	return &celEvaluator{env: env}, nil
}

// CheckExpression checks if an expression is valid.
// If the expression is nil, it returns nil.
func (e *celEvaluator) CheckExpression(expression *v1alpha1.Expression) error {
	if expression == nil {
		return nil
	}

	ast, issues := e.env.Parse(string(*expression))
	if issues != nil && issues.Err() != nil {
		return fmt.Errorf("failed to parse expression: %w", issues.Err())
	}

	_, issues = e.env.Check(ast)
	if issues != nil && issues.Err() != nil {
		return fmt.Errorf("failed to check expression: %w", issues.Err())
	}

	return nil
}

// Evaluate takes an expression and a Kubernetes raw object, and returns the
// evaluation of the expression with the object as the context.
func (e *celEvaluator) Evaluate(expression v1alpha1.Expression, objMap map[string]interface{}) (ref.Val, error) {
	ast, issues := e.env.Parse(string(expression))
	if issues != nil && issues.Err() != nil {
		return nil, fmt.Errorf("failed to parse expression: %w", issues.Err())
	}

	checked, issues := e.env.Check(ast)
	if issues != nil && issues.Err() != nil {
		return nil, fmt.Errorf("failed to check expression: %w", issues.Err())
	}

	// create the program
	prog, err := e.env.Program(checked)
	if err != nil {
		return nil, fmt.Errorf("failed to create program: %w", err)
	}

	// evaluate the expression with the unstructured object
	result, _, err := prog.Eval(objMap)

	if err != nil {
		return nil, fmt.Errorf("failed to evaluate expression: %w", err)
	}

	return result, nil
}
