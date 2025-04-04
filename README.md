# Terraform Generator

An AI-powered Terraform code generator application that creates infrastructure-as-code based on natural language requirements.

## Features

- Convert natural language requirements into Terraform code
- Generate multiple Terraform files (main.tf, variables.tf, outputs.tf)
- Validate generated Terraform code
- Provide expert recommendations for enhancements

## Components

- **Frontend**: Simple HTML/JS UI for interacting with the generator
- **Backend**: Python API using Flask/FastAPI and LangGraph
- **Infrastructure**: Terraform files for deploying on AWS

## Local Development

### Prerequisites
- Python 3.8+
- OpenAI API key

### Setup
1. Clone this repository
2. Install dependencies: \pip install flask langchain_openai langgraph langchain\`r
3. Run the application: \python app.py\`r
4. Open http://localhost:8000 in your browser

## Deployment
Use the included Terraform files to deploy the application on AWS:

\\\ash
terraform init
terraform apply
\\\`r

## License
MIT
