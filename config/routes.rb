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
        post :clear_logs
        post :cleanup_old_logs
        post :get_imap_folders
        post :process_deferred
        post :create_user_from_mail
        post :process_deferred_mail
        post :block_user
        post :delete_all_comments
      get :deferred_status
      end
    end
    
    resources :mail_handler_logs, :only => [:index, :show] do
      collection do
        get :export
        post :move_journal
      end
    end
  end
  
  # Öffentliche Route für Journal-Verschiebung (außerhalb von /admin)
  resources :mail_handler_logs, :only => [] do
    collection do
      post :move_journal
    end
  end
end