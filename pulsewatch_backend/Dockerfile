# Use a lightweight Python base image
FROM python:3.11-slim

# Set the working directory inside the container
WORKDIR /app

# Copy the requirements file and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . .

# Create the upload directory
RUN mkdir -p patient_data

# Expose the port the app runs on
EXPOSE 5000

# Command to run the application using Gunicorn (Production Server)
# We will add gunicorn to requirements.txt next
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:5000", "app:app"]