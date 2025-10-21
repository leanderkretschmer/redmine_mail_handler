# Plugin routes
# See: http://guides.rubyonrails.org/routing.html

RedmineApp::Application.routes.draw do
  # Admin-Routen
  scope '/admin' do
    resources :mail_handler_admin, :only => [:index] do
      collection do
        post :test_connection
        post :test_imap_connection
        post :test_smtp_connection
        post :test_mail
        post :test_reminder
        post :send_bulk_reminder
        post :manual_import
        post :toggle_scheduler
        post :restart_scheduler
        post :toggle_load_balancing
        post :get_imap_folders
        post :process_deferred
        post :create_user_from_mail
        post :process_deferred_mail
        delete :delete_all_comments
        delete :delete_anonymous_comments
        delete :delete_orphaned_attachments
        get :deferred_status
        get :deferred_mails
        post :reload_deferred_mails
        post :rescan_deferred_mails
        post :archive_deferred_mails
      end
    end
    resources :mail_handler_logs, :only => [:index, :show, :destroy] do
      collection do
        delete :clear
        delete :cleanup
        get :export
      end
    end
  end
end