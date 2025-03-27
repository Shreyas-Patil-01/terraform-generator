provider "aws" {
  region = var.region
}

# Create a VPC
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  tags = {
    Name = "\${var.project_name}-vpc"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id
  tags = {
    Name = "\${var.project_name}-igw"
  }
}

# Create a public subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "\${var.region}a"
  tags = {
    Name = "\${var.project_name}-public-subnet"
  }
}

# Create a route table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_igw.id
  }
  tags = {
    Name = "\${var.project_name}-public-rt"
  }
}

# Associate public subnet with public route table
resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Create security group for the EC2 instance
resource "aws_security_group" "app_sg" {
  name        = "\${var.project_name}-sg"
  description = "Security group for Terraform Generator application"
  vpc_id      = aws_vpc.app_vpc.id

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  # HTTP access
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  # Application port access
  ingress {
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Application port access"
  }

  # Outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "\${var.project_name}-sg"
  }
}

# Create EC2 instance
resource "aws_instance" "app_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  subnet_id              = aws_subnet.public_subnet.id

  user_data = <<-EOF
              #!/bin/bash
              # Update system packages
              sudo apt update -y && sudo apt upgrade -y

              # Install required packages
              sudo apt install -y python3-pip python3-venv nginx

              # Create app directory
              mkdir -p /home/ubuntu/terraform-generator
              cd /home/ubuntu/terraform-generator

              # Create app files
              cat > app.py << 'EOL'
              import os
              from typing import TypedDict, Dict
              from flask import Flask, request, jsonify, send_from_directory
              from langgraph.graph import StateGraph, END
              from langchain_openai import ChatOpenAI
              from langchain.prompts import PromptTemplate
              import json

              # Set the OpenAI API key
              os.environ["OPENAI_API_KEY"] = "\${var.openai_api_key}"

              # Initialize the LLM
              llm = ChatOpenAI(model="gpt-4o-mini", temperature=0)

              # Define state
              class AgentState(TypedDict):
                  query: str
                  raw_response: str
                  terraform_files: dict
                  validation_result: str
                  recommendations: str

              # Agent 1: Fetch LLM response (fixed prompt)
              llm_prompt = PromptTemplate(
                  input_variables=["query"],
                  template="""
                  You are a professional Terraform developer with expertise in DevOps and AI. The user has asked: "{query}". 
                  To provide an accurate Terraform solution, follow these steps:
                  1. Understand the user's request and break it down into components (e.g., resources, variables, outputs).
                  2. Reason step-by-step about what Terraform resources, providers, and configurations are needed.
                  3. Generate the Terraform code in a structured JSON format with keys representing .tf filenames (e.g., "main.tf", "variables.tf", "outputs.tf", or others as needed).
                  4. Ensure the code is syntactically correct, follows Terraform best practices, and **always uses variables** for configurable values (e.g., region, bucket name) defined in "variables.tf" with appropriate defaults and descriptions.

                  **Important**: Your response must be a valid JSON string enclosed in ```json``` markers. Do not include any additional text outside the JSON block. Configurable values like region and bucket name must use variables defined in "variables.tf". Here's an example for an S3 bucket:
                  ```json
                  {{
                    "main.tf": "provider \\"aws\\" {{\\n  region = var.region\\n}}\\n\\nresource \\"aws_s3_bucket\\" \\"example\\" {{\\n  bucket = var.bucket_name\\n  acl = \\"public-read\\"\\n}}\\n\\nresource \\"aws_s3_bucket_policy\\" \\"example_policy\\" {{\\n  bucket = aws_s3_bucket.example.id\\n  policy = jsonencode({{\\n    Version = \\"2012-10-17\\"\\n    Statement = [\\n      {{\\n        Effect = \\"Allow\\"\\n        Principal = \\"*\\"\\n        Action = \\"s3:GetObject\\"\\n        Resource = \\"\${{aws_s3_bucket.example.arn}}/*\\"\\n      }}\\n    ]\\n  }})\\n}}",
                    "variables.tf": "variable \\"region\\" {{\\n  description = \\"AWS region\\"\\n  type        = string\\n  default     = \\"us-east-1\\"\\n}}\\n\\nvariable \\"bucket_name\\" {{\\n  description = \\"Name of the S3 bucket\\"\\n  type        = string\\n  default     = \\"my-public-bucket\\"\\n}}",
                    "outputs.tf": "output \\"bucket_name\\" {{\\n  value = aws_s3_bucket.example.id\\n}}\\n\\noutput \\"bucket_arn\\" {{\\n  value = aws_s3_bucket.example.arn\\n}}"
                  }}
                  ```

                  Now, provide the response for "{query}" in the same JSON format, ensuring variables are used and defined in "variables.tf":
                  ```json
                  {{
                    "main.tf": "...",
                    "variables.tf": "...",
                    "outputs.tf": "..."
                  }}
                  ```
                  """
              )

              def fetch_llm_response(state: AgentState) -> AgentState:
                  chain = llm_prompt | llm
                  response = chain.invoke({"query": state["query"]})
                  state["raw_response"] = response.content
                  return state

              # Agent 2: Format Terraform files (dynamic)
              def format_terraform_files(state: AgentState) -> AgentState:
                  try:
                      # Extract content between ```json``` markers
                      raw_response = state["raw_response"]
                      start_marker = "```json\n"
                      end_marker = "\n```"
                      start_idx = raw_response.index(start_marker) + len(start_marker)
                      end_idx = raw_response.index(end_marker)
                      json_content = raw_response[start_idx:end_idx].strip()
                      
                      # Parse the extracted JSON
                      terraform_data = json.loads(json_content)
                      
                      # Dynamically assign all key-value pairs from the JSON
                      state["terraform_files"] = {key: value for key, value in terraform_data.items() if key.endswith(".tf")}
                  except (ValueError, json.JSONDecodeError) as e:
                      print(f"Error parsing JSON: {e}")
                      state["terraform_files"] = {"main.tf": "# Error: Could not parse LLM response"}
                  return state

              # Agent 3: Validate Terraform code (enhanced)
              def validate_terraform_code(state: AgentState) -> AgentState:
                  files_content = "\n".join([f"{key}:\n{value}" for key, value in state["terraform_files"].items()])
                  prompt = """
                  You are a Terraform expert. Thoroughly validate the following Terraform code for:
                  1. Syntax correctness (e.g., correct HCL formatting, valid resource attributes, properly formatted JSON in policies).
                  2. Best practices (e.g., use of variables instead of hardcoded values, provider configuration, resource naming).
                  3. Logical errors (e.g., missing dependencies, invalid references).

                  Terraform Files:
                  {files_content}
                  
                  Provide feedback as a concise string. Examples:
                  - "Valid with no issues"
                  - "Syntax error: malformed JSON in bucket policy in main.tf"
                  - "Best practice violation: hardcoding region in provider; use a variable"
                  """.format(files_content=files_content)
                  response = llm.invoke(prompt)
                  state["validation_result"] = response.content
                  return state

              # Agent 4: Provide recommendations
              def provide_recommendations(state: AgentState) -> AgentState:
                  files_content = "\n".join([f"{key}: {value}" for key, value in state["terraform_files"].items()])
                  prompt = """
                  You are a DevOps expert. Based on the user query "{query}" and the generated Terraform code:
                  {files_content}
                  
                  Provide 2-3 future recommendations to enhance this setup (e.g., scalability, security, cost optimization).
                  Return the recommendations as a single string.
                  """.format(query=state["query"], files_content=files_content)
                  response = llm.invoke(prompt)
                  state["recommendations"] = response.content
                  return state

              # Build the workflow
              workflow = StateGraph(AgentState)
              workflow.add_node("fetch_llm_response", fetch_llm_response)
              workflow.add_node("format_terraform_files", format_terraform_files)
              workflow.add_node("validate_terraform_code", validate_terraform_code)
              workflow.add_node("provide_recommendations", provide_recommendations)

              workflow.add_edge("fetch_llm_response", "format_terraform_files")
              workflow.add_edge("format_terraform_files", "validate_terraform_code")
              workflow.add_edge("validate_terraform_code", "provide_recommendations")
              workflow.add_edge("provide_recommendations", END)

              workflow.set_entry_point("fetch_llm_response")
              app_workflow = workflow.compile()

              # Flask app
              app = Flask(__name__, static_folder='static')

              @app.route('/')
              def index():
                  return send_from_directory('static', 'index.html')

              @app.route('/generate-terraform', methods=['POST'])
              def generate_terraform():
                  try:
                      data = request.json
                      query = data.get('query', '')
                      
                      if not query:
                          return jsonify({'error': 'Query is required'}), 400
                          
                      initial_state = {
                          "query": query,
                          "raw_response": "",
                          "terraform_files": {},
                          "validation_result": "",
                          "recommendations": ""
                      }
                      
                      result = app_workflow.invoke(initial_state)
                      
                      return jsonify({
                          "terraform_files": result["terraform_files"],
                          "validation_result": result["validation_result"],
                          "recommendations": result["recommendations"]
                      })
                  except Exception as e:
                      return jsonify({'error': str(e)}), 500

              if __name__ == '__main__':
                  # Create static directory if it doesn't exist
                  os.makedirs('static', exist_ok=True)
                  
                  app.run(host='0.0.0.0', port=\${var.app_port})
              EOL

              # Create static directory
              mkdir -p static

              # Create index.html
              cat > static/index.html << 'EOL'
              <!DOCTYPE html>
              <html lang="en">
              <head>
                  <meta charset="UTF-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                  <title>Terraform Generator</title>
                  <style>
                      body {
                          font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
                          max-width: 1200px;
                          margin: 0 auto;
                          padding: 20px;
                          background-color: #f7f9fc;
                          color: #333;
                      }
                      h1 {
                          color: #2c3e50;
                          text-align: center;
                          margin-bottom: 30px;
                      }
                      .container {
                          display: flex;
                          flex-direction: column;
                          gap: 20px;
                      }
                      .input-section {
                          background-color: white;
                          padding: 20px;
                          border-radius: 8px;
                          box-shadow: 0 2px 10px rgba(0, 0, 0, 0.1);
                      }
                      .output-section {
                          background-color: white;
                          padding: 20px;
                          border-radius: 8px;
                          box-shadow: 0 2px 10px rgba(0, 0, 0, 0.1);
                          display: none;
                      }
                      textarea {
                          width: 100%;
                          padding: 12px;
                          border: 1px solid #ddd;
                          border-radius: 4px;
                          min-height: 100px;
                          font-family: monospace;
                          resize: vertical;
                      }
                      button {
                          background-color: #3498db;
                          color: white;
                          border: none;
                          padding: 12px 24px;
                          border-radius: 4px;
                          cursor: pointer;
                          font-size: 16px;
                          transition: background-color 0.3s;
                      }
                      button:hover {
                          background-color: #2980b9;
                      }
                      .file-tabs {
                          display: flex;
                          flex-wrap: wrap;
                          gap: 10px;
                          margin-bottom: 10px;
                      }
                      .file-tab {
                          padding: 8px 16px;
                          background-color: #e0e0e0;
                          border-radius: 4px 4px 0 0;
                          cursor: pointer;
                      }
                      .file-tab.active {
                          background-color: #3498db;
                          color: white;
                      }
                      .code-display {
                          background-color: #272822;
                          color: #f8f8f2;
                          padding: 15px;
                          border-radius: 4px;
                          overflow-x: auto;
                          font-family: 'Courier New', Courier, monospace;
                          white-space: pre;
                      }
                      .validation, .recommendations {
                          margin-top: 20px;
                          padding: 15px;
                          border-radius: 4px;
                      }
                      .validation {
                          background-color: #e8f4fc;
                          border-left: 4px solid #3498db;
                      }
                      .recommendations {
                          background-color: #eafaf1;
                          border-left: 4px solid #2ecc71;
                      }
                      h3 {
                          margin-top: 25px;
                          color: #2c3e50;
                      }
                      .loading {
                          text-align: center;
                          padding: 20px;
                          display: none;
                      }
                      .spinner {
                          border: 4px solid rgba(0, 0, 0, 0.1);
                          width: 40px;
                          height: 40px;
                          border-radius: 50%;
                          border-top: 4px solid #3498db;
                          animation: spin 1s linear infinite;
                          margin: 0 auto;
                      }
                      @keyframes spin {
                          0% { transform: rotate(0deg); }
                          100% { transform: rotate(360deg); }
                      }
                  </style>
              </head>
              <body>
                  <h1>Terraform Generator</h1>
                  
                  <div class="container">
                      <div class="input-section">
                          <h3>Enter your requirements:</h3>
                          <textarea id="query-input" placeholder="Example: Create a Terraform script to deploy an AWS S3 bucket with public read access"></textarea>
                          <div style="margin-top: 15px; text-align: center;">
                              <button id="generate-btn">Generate Terraform</button>
                          </div>
                      </div>
                      
                      <div class="loading" id="loading">
                          <div class="spinner"></div>
                          <p>Generating Terraform code...</p>
                      </div>

                      <div class="output-section" id="output-section">
                          <h3>Generated Terraform Files</h3>
                          <div class="file-tabs" id="file-tabs"></div>
                          <div class="code-display" id="code-display"></div>
                          
                          <h3>Validation</h3>
                          <div class="validation" id="validation-result"></div>
                          
                          <h3>Recommendations</h3>
                          <div class="recommendations" id="recommendations"></div>
                      </div>
                  </div>

                  <script>
                      document.addEventListener('DOMContentLoaded', () => {
                          const generateBtn = document.getElementById('generate-btn');
                          const queryInput = document.getElementById('query-input');
                          const outputSection = document.getElementById('output-section');
                          const fileTabs = document.getElementById('file-tabs');
                          const codeDisplay = document.getElementById('code-display');
                          const validationResult = document.getElementById('validation-result');
                          const recommendations = document.getElementById('recommendations');
                          const loading = document.getElementById('loading');
                          
                          let currentFiles = {};

                          generateBtn.addEventListener('click', async () => {
                              const query = queryInput.value.trim();
                              
                              if (!query) {
                                  alert('Please enter your requirements');
                                  return;
                              }
                              
                              outputSection.style.display = 'none';
                              loading.style.display = 'block';
                              
                              try {
                                  const response = await fetch('/generate-terraform', {
                                      method: 'POST',
                                      headers: {
                                          'Content-Type': 'application/json'
                                      },
                                      body: JSON.stringify({ query })
                                  });
                                  
                                  if (!response.ok) {
                                      throw new Error('Failed to generate Terraform code');
                                  }
                                  
                                  const data = await response.json();
                                  displayResults(data);
                              } catch (error) {
                                  alert('Error: ' + error.message);
                              } finally {
                                  loading.style.display = 'none';
                              }
                          });
                          
                          function displayResults(data) {
                              // Store the files
                              currentFiles = data.terraform_files;
                              
                              // Clear previous tabs
                              fileTabs.innerHTML = '';
                              
                              // Create tabs for each file
                              Object.keys(currentFiles).forEach((filename, index) => {
                                  const tab = document.createElement('div');
                                  tab.className = 'file-tab' + (index === 0 ? ' active' : '');
                                  tab.textContent = filename;
                                  tab.addEventListener('click', () => {
                                      // Set active tab
                                      document.querySelectorAll('.file-tab').forEach(t => t.classList.remove('active'));
                                      tab.classList.add('active');
                                      
                                      // Display the file content
                                      codeDisplay.textContent = currentFiles[filename];
                                  });
                                  fileTabs.appendChild(tab);
                              });
                              
                              // Show the first file by default
                              const firstFile = Object.keys(currentFiles)[0];
                              codeDisplay.textContent = currentFiles[firstFile] || 'No files generated';
                              
                              // Display validation and recommendations
                              validationResult.textContent = data.validation_result;
                              recommendations.textContent = data.recommendations;
                              
                              // Show the output section
                              outputSection.style.display = 'block';
                          }
                      });
                  </script>
              </body>
              </html>
              EOL

              # Create virtual environment and install dependencies
              python3 -m venv venv
              source venv/bin/activate
              pip install flask langchain_openai langgraph langchain

              # Create systemd service file
              sudo tee /etc/systemd/system/terraform-generator.service > /dev/null << EOL
              [Unit]
              Description=Terraform Generator Application
              After=network.target

              [Service]
              User=ubuntu
              WorkingDirectory=/home/ubuntu/terraform-generator
              ExecStart=/home/ubuntu/terraform-generator/venv/bin/python app.py
              Restart=always
              RestartSec=5
              StandardOutput=syslog
              StandardError=syslog
              SyslogIdentifier=terraform-generator

              [Install]
              WantedBy=multi-user.target
              EOL

              # Configure Nginx as a reverse proxy
              sudo tee /etc/nginx/sites-available/terraform-generator > /dev/null << EOL
              server {
                  listen 80;
                  server_name _;

                  location / {
                      proxy_pass http://127.0.0.1:\${var.app_port};
                      proxy_set_header Host \\$host;
                      proxy_set_header X-Real-IP \\$remote_addr;
                  }
              }
              EOL

              # Enable the Nginx site
              sudo ln -s /etc/nginx/sites-available/terraform-generator /etc/nginx/sites-enabled/
              sudo rm -f /etc/nginx/sites-enabled/default
              sudo nginx -t && sudo systemctl restart nginx

              # Start the application
              sudo systemctl enable terraform-generator
              sudo systemctl start terraform-generator
              EOF

  tags = {
    Name = "\${var.project_name}-instance"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    delete_on_termination = true
  }

  depends_on = [aws_internet_gateway.app_igw]
}

# Create Elastic IP for EC2 instance
resource "aws_eip" "app_eip" {
  instance = aws_instance.app_instance.id
  domain   = "vpc"
  tags = {
    Name = "\${var.project_name}-eip"
  }
  depends_on = [aws_internet_gateway.app_igw]
}