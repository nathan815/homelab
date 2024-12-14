# Buildx Set Up

This needs to be run before building any docker images here using buildx.

```
docker buildx rm mybuilder
docker buildx create --name mybuilder --config ./buildkitd.toml --use
docker buildx inspect --bootstrap
```
