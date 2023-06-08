#!/usr/bin/env sh


minikube start --force

helm create new-chart
helm install new-chart ./new-chart

helm ls

sleep 10
kubectl get pods
