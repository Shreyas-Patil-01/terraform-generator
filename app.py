import os
from typing import TypedDict, Dict
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from langgraph.graph import StateGraph, END
from langchain_openai import ChatOpenAI
from langchain.prompts import PromptTemplate
import json
import uvicorn
from fastapi.staticfiles import StaticFiles

# Set the OpenAI API key
os.environ["OPENAI_API_KEY"] = os.getenv("OPENAI_API_KEY", "")

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

# FastAPI app
app = FastAPI(title="Terraform Generator API")

# Enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Request model
class QueryRequest(BaseModel):
    query: str

# Response model
class TerraformResponse(BaseModel):
    terraform_files: Dict[str, str]
    validation_result: str
    recommendations: str

@app.post("/generate-terraform", response_model=TerraformResponse)
async def generate_terraform(request: QueryRequest):
    try:
        initial_state = {
            "query": request.query,
            "raw_response": "",
            "terraform_files": {},
            "validation_result": "",
            "recommendations": ""
        }
        
        result = app_workflow.invoke(initial_state)
        
        return {
            "terraform_files": result["terraform_files"],
            "validation_result": result["validation_result"],
            "recommendations": result["recommendations"]
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error generating Terraform: {str(e)}")

# Create a directory for static files
os.makedirs("static", exist_ok=True)

# Serve static files
app.mount("/", StaticFiles(directory="static", html=True), name="static")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)