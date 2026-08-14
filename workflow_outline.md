1. experiment-scoping

    Input: paper pdf, codebase\
    Process: study the paper to learn the work briefly and identify the experiments to perform. Read the paper and codebase examples together (also consult the argparse sections of run scripts) to give one set of hyperparameters per experiment for a mock run per experiment.\
    Output: For each experiment: one command with hyperparam flags, justification for non-obvious hyperparameter choices, dataset(s)/checkpoint(s) needed

2. 	resource-download

    Input: results from 1, hardware information\
    Process: If checkpoints are needed, check against the hardware information (e.g. vram available) and exit if the hardware does not support running of the experiment. Download the datasets/checkpoints needed\
    Output: for each dataset: its absolute storage path

3.	Environment setup

    Input: codebase, results from 1, [paper pdf]\
    Process:  set up the environment with this priority order: lockfiles and pinned requirements (environment.yml, requirements.txt, setup.py/pyproject, Dockerfile) > README instructions > paper > inference from imports. If it's needed to inference from imports, pin package versions to the data of repo's last commit. Explicitly capture the Python version and CUDA/torch compatibility.\
    Output: a conda env, a file listing package versions
4.	Code fix

    Input: results from 1 and 3, codebase\
    Process: for each environment, run the command from 1 and fix the code/env in an error-driven manner:

    1.	Init git
    2.	Run the command
    3.	If any error arises, identify if its due to env or coding error
    4.	If due to env error, feed the error and current env to an env setup skill to try to correct the error
    5.	If due to coding error, fix the code and commit the fix
    6.	Rerun from step 2

    Output: fixed codebase