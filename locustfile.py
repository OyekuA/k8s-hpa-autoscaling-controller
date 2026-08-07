from locust import HttpUser, constant, task


class ComputeHeavyUser(HttpUser):
    wait_time = constant(0)

    @task
    def compute_heavy(self):
        self.client.get("/compute-heavy")
