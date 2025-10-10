# Mail Handler Plugin - Change Summary

## Version 2.3.0: Background Processing for Mail Imports

This version introduces a significant architectural change to improve the performance and reliability of the mail import process. Instead of running the import task within the main Redmine application process, it is now offloaded to a background job.

### Key Changes

- **Asynchronous Mail Import:** The mail import process is no longer executed directly by the scheduler. It is now enqueued as a background job using Redmine's built-in Active Job framework.
- **Improved Responsiveness:** By moving the import process to the background, the main Redmine application remains responsive and is not blocked by potentially long-running mail import tasks. This prevents timeouts and improves the user experience.
- **Enhanced Stability:** Offloading the import process to a separate background worker improves the overall stability of the Redmine instance.

### Actions for System Administrators

#### Configure an Active Job Backend

For the mail import to work correctly in a production environment, you **must** configure an Active Job backend. The default inline backend is not suitable for production as it does not provide the benefits of background processing.

**Recommended Backend: Sidekiq**

We recommend using Sidekiq with Redis for robust and efficient background job processing.

1.  **Install Redis:**
    - Follow the official instructions to install Redis on your server: [https://redis.io/topics/quickstart](https://redis.io/topics/quickstart)

2.  **Add Sidekiq to your `Gemfile.local`:**
    - Create or edit the `Gemfile.local` file in your Redmine root directory and add the following line:
      ```ruby
      gem 'sidekiq'
      ```

3.  **Install the Gem:**
    - Run `bundle install` in your Redmine root directory.

4.  **Configure Redmine to use Sidekiq:**
    - In your `config/application.rb` file, set the queue adapter:
      ```ruby
      config.active_job.queue_adapter = :sidekiq
      ```

5.  **Run the Sidekiq Worker:**
    - Start the Sidekiq worker process from your Redmine root directory:
      ```bash
      bundle exec sidekiq -q mail_handler -q default
      ```
    - It is crucial to include the `mail_handler` queue, as this is the queue used by the plugin.

#### Restart Redmine

- **IMPORTANT:** After making these changes, you must **restart the Redmine application server** (e.g., Puma, Unicorn, Passenger) for the changes to take effect.

#### Monitoring

- Monitor the status of the background jobs in your chosen backend's monitoring interface (e.g., the Sidekiq Web UI).
- Check the plugin's logs under `Administration -> Mail Handler -> Logs` to monitor the import process and identify any potential issues.
