/*
Copyright 2026.

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

package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// NOTE: json tags are required. Any new fields you add must have json tags for the fields to be serialized.

// PodRestorePhase is the high-level state of a PodRestore operation.
type PodRestorePhase string

const (
	// PodRestorePhasePending means the PodRestore has been accepted but the
	// restored Pod has not been created yet.
	PodRestorePhasePending PodRestorePhase = "Pending"

	// PodRestorePhaseRestoring means the Pod has been created and the kubelet
	// is driving the sandbox/container lifecycle.
	PodRestorePhaseRestoring PodRestorePhase = "Restoring"

	// PodRestorePhaseRunning means all containers in the restored Pod have
	// reached the Running state.
	PodRestorePhaseRunning PodRestorePhase = "Running"

	// PodRestorePhaseFailed means the restore could not be completed.
	PodRestorePhaseFailed PodRestorePhase = "Failed"
)

// ContainerRestoreSpec maps a single container to its checkpoint archive and
// the original base image. Both fields are required for every container being
// restored.
type ContainerRestoreSpec struct {
	// Name is the container name, matching the original pod's container name.
	Name string `json:"name"`

	// CheckpointPath is the absolute path of the checkpoint .tar archive on
	// NodeName (e.g. /var/lib/kubelet/checkpoints/checkpoint-pod_ns-ctr-ts.tar).
	CheckpointPath string `json:"checkpointPath"`

	// BaseImage is the original container image reference. The kubelet requires
	// a valid image to pass its image-pull gate; the runtime then restores the
	// container state from the checkpoint archive rather than starting fresh.
	BaseImage string `json:"baseImage"`
}

// PodTemplateOverridesSpec carries optional pod-level fields that are merged
// into the Pod the operator creates. Use this to attach extra labels, tweak
// annotations, or set a custom service account on the restored pod.
type PodTemplateOverridesSpec struct {
	// Labels are merged into the restored Pod's metadata.labels.
	// +optional
	Labels map[string]string `json:"labels,omitempty"`

	// Annotations are merged into the restored Pod's metadata.annotations.
	// Annotations set by the operator (e.g. restore.criu.org/checkpoint-path)
	// take precedence over any values provided here.
	// +optional
	Annotations map[string]string `json:"annotations,omitempty"`

	// ServiceAccountName overrides the service account for the restored Pod.
	// +optional
	ServiceAccountName string `json:"serviceAccountName,omitempty"`
}

// PodRestoreSpec defines the desired state of PodRestore.
type PodRestoreSpec struct {
	// NodeName is the node on which the checkpoint archives reside. The
	// restored Pod is pinned to this node via spec.nodeName so that the
	// runtime can access the local .tar files directly.
	NodeName string `json:"nodeName"`

	// Containers lists the per-container restore sources. Every container
	// that should be restored must have an entry here.
	// +kubebuilder:validation:MinItems=1
	Containers []ContainerRestoreSpec `json:"containers"`

	// RuntimeClassName pins the restored Pod to a specific RuntimeClass.
	// Set this to a CRIU-aware handler (e.g. "criu-restore") when using the
	// RuntimeClass restore path so the correct OCI runtime wrapper is invoked.
	// When omitted the cluster default is used.
	// +optional
	RuntimeClassName *string `json:"runtimeClassName,omitempty"`

	// PodTemplateOverrides allows customising labels, annotations, and other
	// pod-level fields on the Pod that the operator creates.
	// +optional
	PodTemplateOverrides *PodTemplateOverridesSpec `json:"podTemplateOverrides,omitempty"`
}

// PodRestoreStatus defines the observed state of PodRestore.
type PodRestoreStatus struct {
	// Phase is the current high-level state of the restore operation.
	// +optional
	Phase PodRestorePhase `json:"phase,omitempty"`

	// PodName is the name of the Pod created and owned by this PodRestore.
	// +optional
	PodName string `json:"podName,omitempty"`

	// StartTime is when the operator first processed this PodRestore.
	// +optional
	StartTime *metav1.Time `json:"startTime,omitempty"`

	// CompletionTime is when the Pod reached Running state or the restore
	// was marked Failed.
	// +optional
	CompletionTime *metav1.Time `json:"completionTime,omitempty"`

	// Message holds the most recent human-readable error or status detail.
	// +optional
	Message string `json:"message,omitempty"`

	// ObservedGeneration is the most recent spec generation the controller
	// has reconciled.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Conditions represent the latest available observations of the restore
	// state.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Phase",type="string",JSONPath=".status.phase"
// +kubebuilder:printcolumn:name="Node",type="string",JSONPath=".spec.nodeName"
// +kubebuilder:printcolumn:name="Pod",type="string",JSONPath=".status.podName"
// +kubebuilder:printcolumn:name="Age",type="date",JSONPath=".metadata.creationTimestamp"

// PodRestore is the Schema for the podrestores API.
// It drives the restore of one or more checkpointed containers as a new Pod
// on the node where the checkpoint archives reside.
type PodRestore struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// +required
	Spec PodRestoreSpec `json:"spec"`

	// +optional
	Status PodRestoreStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// PodRestoreList contains a list of PodRestore.
type PodRestoreList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []PodRestore `json:"items"`
}

func init() {
	SchemeBuilder.Register(&PodRestore{}, &PodRestoreList{})
}
