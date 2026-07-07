# Use the exact same base image you are currently using
FROM pennlinc/qsiprep:latest

# Create the symlink to satisfy the hard-coded requirement
RUN ln -s /app/.pixi/envs/qsiprep/bin/eddy_cuda11.0 /app/.pixi/envs/qsiprep/bin/eddy_cuda10.2